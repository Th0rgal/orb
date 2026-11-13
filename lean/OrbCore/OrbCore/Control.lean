/-
  OrbCore.Control: Pure-Lean Core HTTP/WS Gateway (`sandboxed-sh`), Fail-Closed Startup Security,
  JWT Subprotocol Auth (`:80/api/console/ws`), Privilege Lease Verification, Mission Control,
  Automations & Model-Routing Dispatcher (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import Std.Data.HashMap
import LeanSys
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.PrivdShared
import OrbBin.GitWorkspace
import OrbBin.ClaudeControl
import OrbCore.Spec
import OrbCore.Store
import OrbCore.Search
import OrbCore.Harness
import OrbCore.Proxy
import OrbCore.ProxyModelRouting
import OrbCore.Cyber
import OrbCore.Skills
import OrbCore.AuthSidecar
import OrbCore.Managed
import OrbCore.MemoryAndCloud
import OrbCore.HarnessSessionRegistry
import OrbCore.QueueCont
import OrbCore.R7Core
import OrbCore.TelemetryAndVoice
import OrbCore.LegacyHydrate
import OrbCore.SecretAndApproval
import OrbCore.RemoteFleetAndRelay
import OrbCore.ManagedProviderSealing
import OrbCore.RemoteDispatch
import OrbCore.ProjectFilesAndController
import OrbCore.CloudHttpAndWorker
import OrbCore.ProviderUsageAndLogin
import OrbCore.ResourcesAndSystem
import OrbCore.McpGateway
import OrbNetLeaf.TlsHttp
import OrbNetLeaf.Gzip

namespace OrbCore.Control

open LeanSys.Posix
open LeanSys.Http
open LeanSys.WebSocket
open LeanSys.Auth
open LeanSys.Codec
open Orb.Kernel
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Spec
open OrbCore.Store
open OrbCore.Search
open OrbCore.Harness
open OrbCore.Proxy
open OrbCore.Cyber
open OrbCore.Skills
open OrbCore.AuthSidecar
open OrbCore.Managed
open OrbCore.MemoryAndCloud
open OrbCore.HarnessSessionRegistry
open OrbCore.QueueCont
open OrbCore.R7Core
open OrbCore.TelemetryAndVoice
open OrbCore.LegacyHydrate
open OrbCore.SecretAndApproval
open OrbCore.RemoteFleetAndRelay
open OrbCore.RemoteDispatch
open OrbCore.ProjectFilesAndController
open OrbCore.CloudHttpAndWorker
open OrbCore.ProviderUsageAndLogin
open OrbCore.ResourcesAndSystem
open OrbCore.McpGateway
open OrbNetLeaf.TlsHttp

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
  askSandboxTmpRoot          : String := ""
  deriving Repr, DecidableEq

/-- Live runtime state for the `sandboxed-sh` HTTP/WS server. -/
structure CoreAppState where
  cfg            : CoreConfig
  store          : CoreStore
  searchIdx?     : Option SearchIndex
  managedRef     : IO.Ref ManagedFleetState
  chainsRef      : IO.Ref (Array RoutingChain)
  proxyCooldownsRef : IO.Ref (Array AccountCooldown)
  seqRef         : IO.Ref UInt64
  pacingTracker?  : Option ProxyPacingTracker := none
  healthTracker?  : Option ProviderHealthTracker := none
  proxyMockTransport? : Option (ProviderTarget → IO (Except String HttpsResponse)) := none
  authRoot        : String := ""
  authRotation?   : Option AuthRotationHandle := none
  cliProxySessionsRef? : Option (IO.Ref (Array CliProxyLoginSession)) := none
  memTokenCache?  : Option MemoryTokenCache := none
  cloudWakeup?    : Option CloudWorkerWakeup := none
  bunkerStateRef? : Option (IO.Ref UInt8) := none
  managedStore?   : Option ManagedComputeStore := none
  managedProvisioningOverride? : Option (ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig) := none
  bootstrapAdminId : String := ""
  telemetrySink?  : Option TelemetrySink := none
  voiceSlots?     : Option VoiceRelaySlots := none
  voiceEndpointOverride? : Option String := none
  warmMgr?        : Option OrbBin.ClaudeControl.WarmHarnessManager := none
  warmHarnessBinOverride? : Option String := none
  pendingControlCallsRef? : Option (IO.Ref (Array (String × String))) := none
  broadcastHub?   : Option BroadcastHub := none
  relayHub?       : Option RelayHub := none
  cloudHub?       : Option CloudRuntimeHub := none
  providerHub?    : Option ProviderRuntimeHub := none
  systemHub?      : Option SystemRuntimeHub := none
  remoteSup?      : Option RemoteJobSupervisor := none

/-- Authenticated multi-user request principal resolved by `resolveCallerPrincipal?`. -/
structure CallerPrincipal where
  userId              : String
  username            : String
  role                : String := "member"
  unixUsername?       : Option String := none
  sessionEpoch        : UInt64 := 1
  disabled            : Bool := false
  dailySpendCapCents? : Option UInt64 := none
  isLegacyUnscoped    : Bool := false
  deriving Repr, DecidableEq, Inhabited

def CallerPrincipal.ofUserRecord (u : UserRecord) (isLegacyUnscoped : Bool := false) : CallerPrincipal := {
  userId              := u.id
  username            := u.username
  role                := if u.role == "admin" then "admin" else "member"
  unixUsername?       := u.unixUsername?
  sessionEpoch        := u.sessionEpoch
  disabled            := u.disabled
  dailySpendCapCents? := u.dailySpendCapCents?
  isLegacyUnscoped    := isLegacyUnscoped
}

/-- Maximum concurrent unexpired CLIProxy login sessions held in `cliProxySessionsRef?`. -/
def maxCliProxyLoginSessions : Nat := 64

/-- Publish a live routing-chain update to `st.chainsRef` and advance `ProviderHealthTracker.routeGeneration`
    whenever the published chain snapshot actually changes (or `forceBump == true` on explicit write endpoints)
    so any concurrent in-flight `/v1/*` attempt planned under an older `routeGeneration` fails closed (`0`). -/
def publishRoutingChainsUpdate
    (st : CoreAppState)
    (chains : Array RoutingChain)
    (forceBump : Bool := true) : IO UInt64 := do
  let prev ← st.chainsRef.get
  st.chainsRef.set chains
  match st.healthTracker? with
  | some htr =>
    if forceBump || prev != chains then
      bumpRouteGeneration htr
    else
      currentRouteGeneration htr
  | none => pure 1

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
  let rawWork := ((← IO.getEnv "WORKING_DIR").getD "").trimAscii.toString
  let workingDir ←
    if rawWork.isEmpty || rawWork == "." then
      pure (← IO.currentDir).toString
    else
      pure rawWork
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
  let askTmpA := ((← IO.getEnv "SANDBOXED_SH_ASK_TMP_ROOT").getD "").trimAscii.toString
  let askTmpB := ((← IO.getEnv "TMPDIR").getD "").trimAscii.toString
  let askTmp := if !askTmpA.isEmpty then askTmpA else if !askTmpB.isEmpty then askTmpB else "/tmp"
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
    askSandboxTmpRoot := askTmp
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

/-- Mint a multi-user HMAC-SHA256 bearer/WS session token:
    `orb-jwt-v2:<userId>:<role>:<sessionEpoch>:<expEpochSec>.<hmacHex>`. -/
def mintSessionTokenV2
    (secret userId role : String)
    (sessionEpoch expEpochSec : UInt64) : String :=
  let cleanRole := if role == "admin" then "admin" else "member"
  let payload := s!"orb-jwt-v2:{userId}:{cleanRole}:{sessionEpoch}:{expEpochSec}"
  let hex := hmacSha256Hex secret payload
  s!"{payload}.{hex}"

/-- Verify an `orb-jwt-v2` session token against `secret` and `nowEpochSec`,
    returning `(userId, role, sessionEpoch, expEpochSec)`. -/
def verifySessionTokenV2
    (secret token : String)
    (nowEpochSec : UInt64) : Option (String × String × UInt64 × UInt64) :=
  if secret.isEmpty || !token.startsWith "orb-jwt-v2:" then none
  else
    match token.splitOn "." with
    | [payload, sigHex] =>
      match payload.splitOn ":" with
      | ["orb-jwt-v2", userId, role, epochStr, expStr] =>
        match epochStr.toNat?, expStr.toNat? with
        | some epNat, some expNat =>
          if userId.isEmpty || (role != "admin" && role != "member") then none
          else
            let sessEp := epNat.toUInt64
            let exp := expNat.toUInt64
            let expected := mintSessionTokenV2 secret userId role sessEp exp
            if ctEqSlice (ByteSlice.ofString s!"{payload}.{sigHex}") (ByteSlice.ofString expected) &&
               nowEpochSec < exp then
              some (userId, role, sessEp, exp)
            else
              none
        | _, _ => none
      | _ => none
    | _ => none

private def effectiveJwtSecret (cfg : CoreConfig) : String :=
  if cfg.jwtSecret.isEmpty then "dev-mode-ephemeral-jwt-secret-012345" else cfg.jwtSecret

private def verifyAnySessionTokenExp? (secret token : String) (nowEpochSec : UInt64) : Option UInt64 :=
  if token.startsWith "orb-jwt-v2:" then
    (verifySessionTokenV2 secret token nowEpochSec).map (fun (_, _, _, exp) => exp)
  else if token.startsWith "eyJ" then
    (verifyHs256Jwt? secret token nowEpochSec).map (fun (_, _, exp) => exp)
  else
    verifySessionToken secret token nowEpochSec

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

/-- Extract bearer or Anthropic `x-api-key` token on `/v1/*` proxy requests. -/
def extractProxyToken? (hdrs : Array (String × String)) (nowEpochSec : UInt64 := 0) : Option String :=
  match extractBearerToken? hdrs nowEpochSec with
  | some t => some t
  | none =>
    match lookupHeaderCI hdrs "x-api-key" with
    | some k =>
      let clean := k.trimAscii.toString
      if clean.isEmpty then none else some clean
    | none => none

/-- Authenticate `:80/api/console/ws`, `/api/monitoring/ws`, `/api/desktop/stream`, and `/api/workspaces/:id/shell`
    strictly through `verifyConsoleWsAuth` (`OrbCore.Spec`), rejecting conflicting dual credentials. -/
def authenticateConsoleWsUpgrade (cfg : CoreConfig) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : Bool :=
  if cfg.devMode then true
  else
    let subTok? := extractWsJwtSubproto? hdrs
    let bearTok? := extractBearerToken? hdrs nowEpochSec
    let sec := effectiveJwtSecret cfg
    let subExp? := subTok?.bind (verifyAnySessionTokenExp? sec · nowEpochSec)
    let bearExp? := bearTok?.bind (verifyAnySessionTokenExp? sec · nowEpochSec)
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
          (match username? with | none => true | some u => u.isEmpty || u == "admin") &&
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
      (verifyAnySessionTokenExp? (effectiveJwtSecret cfg) tok nowEpochSec).isSome ||
      verifyLoginCredentials cfg none tok

/-- Resolve `CallerPrincipal` against `users` (`orb-jwt-v2` live session epoch + `!disabled` check
    via `Orb.Kernel.multiuserRbacStep`, or bootstrap-admin / legacy unscoped fallback). -/
def resolveCallerPrincipal?
    (st : CoreAppState)
    (hdrs : Array (String × String))
    (nowEpochSec : UInt64)
    (allowWsSubproto : Bool := false) : IO (Option CallerPrincipal) := do
  let sec := effectiveJwtSecret st.cfg
  let rawTok? :=
    match extractBearerToken? hdrs nowEpochSec with
    | some b => some b
    | none => if allowWsSubproto then extractWsJwtSubproto? hdrs else none
  if let some tok := rawTok? then
    if tok.startsWith "orb-jwt-v2:" then
      let some (uid, _tokRole, tokEpoch, _exp) := verifySessionTokenV2 sec tok nowEpochSec
        | return none
      let some u ← getUserById? st.store uid
        | return none
      let epochMatch : UInt8 := if u.sessionEpoch == tokEpoch then 1 else 0
      let disFlag : UInt8 := if u.disabled then 1 else 0
      let roleCode : UInt8 := if u.role == "admin" then 1 else 0
      let rbacWord := Orb.Kernel.multiuserRbacStep 1 disFlag epochMatch roleCode 0 1 0
      if (rbacWord &&& 1) != 1 then
        return none
      return some (CallerPrincipal.ofUserRecord u false)
    if tok.startsWith "eyJ" then
      let some (jwtSub, jwtUser, _exp) := verifyHs256Jwt? sec tok nowEpochSec
        | return none
      let multiUsers : Bool ← do
        match ← execParamQuery st.store.missionsDb "SELECT COUNT(*) FROM users WHERE disabled=0;" #[] with
        | .ok rows => pure (decide (((((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 1)))
        | .error _ => pure false
      let singleTenantUnscoped := !multiUsers && (parseConfiguredUsers st.cfg.usersJson).isEmpty
      if let some u ← getUserById? st.store jwtSub then
        if u.disabled then return none
        return some (CallerPrincipal.ofUserRecord u singleTenantUnscoped)
      if let some adm ← getBootstrapAdmin? st.store then
        if adm.disabled then return none
        return some (CallerPrincipal.ofUserRecord adm singleTenantUnscoped)
      return some {
        userId           := jwtSub
        username         := if jwtUser.isEmpty then "admin" else jwtUser
        role             := "admin"
        unixUsername?    := none
        sessionEpoch     := 1
        disabled         := false
        dailySpendCapCents? := none
        isLegacyUnscoped := singleTenantUnscoped
      }
  if !authenticateHttpBearer st.cfg hdrs nowEpochSec &&
     !(allowWsSubproto && authenticateConsoleWsUpgrade st.cfg hdrs nowEpochSec) then
    return none
  if !st.bootstrapAdminId.isEmpty then
    if let some adm ← getUserById? st.store st.bootstrapAdminId then
      if !adm.disabled then
        return some (CallerPrincipal.ofUserRecord adm false)
  if let some adm ← getBootstrapAdmin? st.store then
    return some (CallerPrincipal.ofUserRecord adm (st.bootstrapAdminId.isEmpty))
  return some {
    userId           := ""
    username         := "admin"
    role             := "admin"
    unixUsername?    := none
    sessionEpoch     := 1
    disabled         := false
    dailySpendCapCents? := none
    isLegacyUnscoped := true
  }

/-- Authenticate `/v1/*` LLM proxy requests (`mission_proxy_token`, `SANDBOXED_PROXY_SECRET`, or Core bearer/`x-api-key`). -/
def authenticateProxyRequest (st : CoreAppState) (hdrs : Array (String × String)) (nowEpochSec : UInt64) : IO Bool := do
  if let some pTok := extractProxyToken? hdrs nowEpochSec then
    if pTok.startsWith "orb-mpt-v1_" then
      return (← resolveMissionProxyToken? st.store pTok nowEpochSec).isSome
    if !st.cfg.proxySecret.isEmpty &&
       ctEqSlice (ByteSlice.ofString pTok) (ByteSlice.ofString st.cfg.proxySecret) then
      return true
    if pTok.startsWith "orb-jwt-v2:" then
      let sec := effectiveJwtSecret st.cfg
      if let some (uid, _, tokEp, _) := verifySessionTokenV2 sec pTok nowEpochSec then
        if let some u ← getUserById? st.store uid then
          return !u.disabled && u.sessionEpoch == tokEp
      return false
    if pTok.startsWith "eyJ" then
      return (verifyHs256Jwt? (effectiveJwtSecret st.cfg) pTok nowEpochSec).isSome
    if (← verifyProxyApiKeyFile st.store.rootDir pTok (formatEpochIso8601Utc nowEpochSec)) then
      return true
    if st.cfg.proxySecret.isEmpty &&
       ((verifySessionToken (effectiveJwtSecret st.cfg) pTok nowEpochSec).isSome ||
        verifyLoginCredentials st.cfg none pTok) then
      return true
    return false
  if !st.cfg.proxySecret.isEmpty then
    return false
  return (← resolveCallerPrincipal? st hdrs nowEpochSec).isSome

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
  | "active" | "awaiting_user" | "paused" | "pending" | "waiting_background" | "waiting_rate_limit" => true
  | _ => false

/-- Return `some cap` only when `parallelMissions?` is strictly positive (`> 0`). -/
def enforcedProjectParallelCap? (parallelMissions? : Option Int) : Option Nat :=
  match parallelMissions? with
  | some c => if c > 0 then some c.toNat else none
  | none => none

private partial def trimTrailingSlashes (p : String) : String :=
  if p.length > 1 && p.endsWith "/" then
    trimTrailingSlashes (p.dropEnd 1 |>.toString)
  else
    p

private def resolveConfinedTargetPath (realBase cand : String) : IO (Except String String) := do
  let segs := (cand.splitOn "/").filter (fun s => !s.isEmpty && s != ".")
  if segs.any (fun s => s == "..") then
    return .error "working_directory_parent_traversal_rejected"
  let basePrefix := if realBase == "/" then "/" else realBase ++ "/"
  let mut splitIdx := segs.length
  let mut foundExisting := false
  let mut resolvedAnc := "/"
  while splitIdx > 0 && !foundExisting do
    let ancPath := "/" ++ String.intercalate "/" (segs.take splitIdx)
    if (← System.FilePath.pathExists ancPath) then
      try
        let rp ← IO.FS.realPath (System.FilePath.mk ancPath)
        resolvedAnc := trimTrailingSlashes rp.toString
        foundExisting := true
      catch _ =>
        return .error "working_directory_realpath_failed"
    else
      splitIdx := splitIdx - 1
  if !foundExisting then
    try
      let rp ← IO.FS.realPath (System.FilePath.mk "/")
      resolvedAnc := trimTrailingSlashes rp.toString
    catch _ =>
      resolvedAnc := "/"
  let tailSegs := segs.drop splitIdx
  let finalPath :=
    if tailSegs.isEmpty then resolvedAnc
    else if resolvedAnc == "/" then "/" ++ String.intercalate "/" tailSegs
    else resolvedAnc ++ "/" ++ String.intercalate "/" tailSegs
  if finalPath == realBase || finalPath.startsWith basePrefix then
    return .ok finalPath
  else
    return .error "working_directory_symlink_escape_rejected"

/-- Confine requested mission `working_directory` under `baseDir` (rejects `..` traversal, NUL bytes,
    trailing-slash root-boundary drift, and symlink escapes including non-existent leaf paths under symlinked ancestors). -/
def confineWorkingDirectory (baseDir rawDir : String) : IO (Except String String) := do
  let rawBase := baseDir.trimAscii.toString
  let curDir ← IO.currentDir
  let cwd := trimTrailingSlashes curDir.toString
  let cleanBase :=
    if rawBase.isEmpty || rawBase == "." then
      cwd
    else if rawBase.startsWith "/" then
      trimTrailingSlashes rawBase
    else
      trimTrailingSlashes (if cwd == "/" then s!"/{rawBase}" else s!"{cwd}/{rawBase}")
  let realBase ← try
      let rp ← IO.FS.realPath (System.FilePath.mk cleanBase)
      pure (trimTrailingSlashes rp.toString)
    catch _ =>
      pure cleanBase
  let t := trimTrailingSlashes rawDir.trimAscii.toString
  if t.isEmpty || t == "." then
    return .ok realBase
  else if t.toList.any (fun c => c.toNat == 0) then
    return .error "invalid_working_directory_nul"
  else
    let segs := t.splitOn "/"
    if segs.any (fun s => s == "..") then
      return .error "working_directory_parent_traversal_rejected"
    else
      let cand :=
        if t == cleanBase || t.startsWith (if cleanBase == "/" then "/" else cleanBase ++ "/") ||
           t == realBase || t.startsWith (if realBase == "/" then "/" else realBase ++ "/") then
          t
        else if !t.startsWith "/" then
          let rel := if t.startsWith "./" then (t.drop 2).toString else t
          if rel.isEmpty then realBase else s!"{if realBase == "/" then "" else realBase}/{rel}"
        else
          ""
      if cand.isEmpty then
        return .error "working_directory_outside_workspace_root"
      resolveConfinedTargetPath realBase cand

private def providerSlugOf (s : String) : String :=
  String.ofList (s.toLower.toList.filter (·.isAlphanum))

private def matchProviderForChainTarget? (providers : Array AIProviderRecord) (acctId provId : String) : Option AIProviderRecord :=
  let stripped := if provId.startsWith "custom:" then (provId.drop 7).toString else provId
  let slug := providerSlugOf stripped
  providers.find? fun p =>
    p.enabled && (
      p.id == acctId ||
      p.id == stripped ||
      (!provId.startsWith "custom:" && p.providerType == provId) ||
      (!slug.isEmpty && providerSlugOf p.name == slug)
    )

private def defaultProviderBaseUrl (provType : String) : String :=
  match provType with
  | "muse"        => "https://api.meta.ai"
  | "anthropic"   => "https://api.anthropic.com"
  | "xai"         => "https://api.x.ai"
  | "open-router" => "https://openrouter.ai/api"
  | "cerebras"    => "https://api.cerebras.ai"
  | "groq"        => "https://api.groq.com/openai"
  | "mistral"     => "https://api.mistral.ai"
  | "minimax"     => "https://api.minimax.io"
  | "zai"         => "https://api.z.ai/api/paas/v4"
  | "kimi"        => "https://api.kimi.com/coding"
  | "google"      => "https://generativelanguage.googleapis.com/v1beta/openai"
  | "openai"      => "https://api.openai.com"
  -- Unsupported/explicit-only providers must never leak their key to OpenAI.
  | _             => ""

private def loadSnapshotModelsForProvider (pid : String) : IO (Array (String × String × String)) := do
  let mut out : Array (String × String × String) := #[]
  for prof in #["oauth", "api"] do
    let fp : System.FilePath := s!"catalog/snapshots/{pid}-{prof}.json"
    if (← fp.pathExists) then
      if let some raw ← (try some <$> IO.FS.readFile fp catch _ => pure none) then
        if let .ok jv := OrbBin.Json.parse raw then
          if let some arr := jv.fieldArr? "models" then
            for m in arr do
              let mid := (m.fieldStr? "id").getD ""
              if !mid.isEmpty && !out.any (fun (k, _, _) => k == mid) then
                let mname := (m.fieldStr? "name").getD mid
                let mdesc := (m.fieldStr? "description").getD ""
                out := out.push (mid, mname, mdesc)
  return out

private def fallbackCatalogProviders : Array (String × String × String × String × Array (String × String × String)) := #[
  ("anthropic", "Claude (Subscription)", "subscription", "Included in Claude Max", #[
    ("claude-opus-5-5", "Claude Opus 5.5", "Default for complex agentic coding, always-adaptive thinking, 1M context"),
    ("claude-opus-5", "Claude Opus 5", "Complex agentic coding, adaptive thinking, 1M context"),
    ("claude-fable-5-2", "Claude Fable 5.2", "Demanding reasoning and long-horizon agentic work, adaptive thinking (efforts low..max), 1M context"),
    ("claude-mythos-5-2", "Claude Mythos 5.2", "Mythos-class reasoning and cyber/life-sciences research (requires verified organization access), 1M context"),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Latest Sonnet, efficient for routine tasks"),
    ("claude-sonnet-4-6", "Claude Sonnet 4.6", "Balanced speed and capability"),
    ("claude-haiku-5-5", "Claude Haiku 5.5", "Latest Haiku, fastest for quick answers")
  ]),
  ("openai", "OpenAI (Subscription)", "subscription", "ChatGPT Plus/Pro via OAuth", #[
    ("gpt-6.1-sol", "GPT-6.1 Sol", "Newest Codex flagship (efforts low..ultra). Default."),
    ("gpt-6.1-terra", "GPT-6.1 Terra", "GPT-6.1 model with lower cost than Sol (efforts low..ultra)."),
    ("gpt-6-astra", "GPT-6 Astra", "OpenAI's GPT-6 flagship in Codex (efforts low..ultra)."),
    ("gpt-6-sol", "GPT-6 Sol", "GPT-6 model for complex reasoning and coding (efforts low..ultra)."),
    ("gpt-6-luna", "GPT-6 Luna", "GPT-6 model optimized for speed and cost (efforts low..max)."),
    ("gpt-5.6", "GPT-5.6", "Flagship GPT-5.6 reasoning and coding model")
  ]),
  ("muse", "Meta Muse", "api_key", "Meta's Muse family via api.meta.ai (OpenCode native meta Responses provider)", #[
    ("muse-wonder-1.0", "Muse Wonder 1.0", "Flagship frontier reasoning and planning model for complex agentic coding, 1M context (standard API tier)"),
    ("muse-ember-1.0", "Muse Ember 1.0", "Fast, low-cost reasoning model for high-volume agent subtasks and tool calls, 1M context"),
    ("muse-spark-1.3-contributor", "Muse Spark 1.3 Contributor", "Spark 1.3, data-sharing tier (~12x cheaper)"),
    ("muse-spark-1.3", "Muse Spark 1.3", "Spark 1.3, no-training tier")
  ]),
  ("xai", "xAI (API Key)", "pay-per-token", "Grok models via xAI API key", #[
    ("grok-4.7", "Grok 4.7", "Latest flagship Grok model"),
    ("grok-4.7-build-fast", "Grok 4.7 Build (Fast)", "Faster Grok 4.7 variant for coding agents"),
    ("grok-4.6", "Grok 4.6", "Previous flagship Grok model")
  ]),
  ("open-router", "OpenRouter (API Key)", "pay-per-token", "Aggregator routing through OpenRouter", #[
    ("anthropic/claude-opus-5.5", "Claude Opus 5.5", "Anthropic Claude via OpenRouter"),
    ("anthropic/claude-opus-5", "Claude Opus 5", "Anthropic Claude via OpenRouter"),
    ("anthropic/claude-fable-5.2", "Claude Fable 5.2", "Anthropic Claude Fable 5.2 via OpenRouter"),
    ("anthropic/claude-mythos-5.2", "Claude Mythos 5.2", "Anthropic Claude Mythos 5.2 via OpenRouter"),
    ("meta/muse-wonder", "Meta Muse Wonder 1.0", "Meta Muse Wonder 1.0 via OpenRouter"),
    ("meta/muse-ember", "Meta Muse Ember 1.0", "Meta Muse Ember 1.0 via OpenRouter"),
    ("openai/gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI GPT-6.1 Sol via OpenRouter"),
    ("openai/gpt-6-astra", "OpenAI GPT-6 Astra", "OpenAI GPT-6 Astra via OpenRouter")
  ])
]

private def renderProviderCatalogJson (st : CoreStore) (caller : CallerPrincipal) : IO String := do
  let isAdm := caller.isLegacyUnscoped || caller.role == "admin"
  let uPrefs ← if caller.isLegacyUnscoped then pure #[] else getUserProviderPrefs st caller.userId
  let dbProviders ← listAIProviders st
  let mut configuredIds : Array String := #[]
  for p in dbProviders do
    let effEn := if caller.isLegacyUnscoped then p.enabled else (p.enabled && (isAdm || !p.apiKey.isEmpty) && isUserProviderEnabled uPrefs p.id)
    if effEn then
      let cid := if p.providerType == "custom" then s!"custom:{p.id}" else p.providerType
      if !cid.isEmpty && !configuredIds.contains cid then
        configuredIds := configuredIds.push cid
  let providersFile : System.FilePath := "catalog/providers.json"
  let mut catalogEntries : Array (String × String × String × String × Array (String × String × String)) := #[]
  if (← providersFile.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile providersFile catch _ => pure none) then
      if let .ok jv := OrbBin.Json.parse raw then
        if let some provArr := jv.fieldArr? "providers" then
          for pr in provArr do
            let pid := (pr.fieldStr? "id").getD ""
            if !pid.isEmpty then
              let pname := (pr.fieldStr? "name").getD pid
              let pbilling := (pr.fieldStr? "billing").getD ""
              let pdesc := (pr.fieldStr? "description").getD ""
              let snapModels ← loadSnapshotModelsForProvider pid
              catalogEntries := catalogEntries.push (pid, pname, pbilling, pdesc, snapModels)
  if catalogEntries.isEmpty then
    catalogEntries := fallbackCatalogProviders
  for p in dbProviders do
    let effEn := if caller.isLegacyUnscoped then p.enabled else (p.enabled && (isAdm || !p.apiKey.isEmpty) && isUserProviderEnabled uPrefs p.id)
    if effEn && p.providerType == "custom" then
      let cModels := p.customModels.filterMap fun cm =>
        let mid := cm.id.trimAscii.toString
        if mid.isEmpty then none else some (mid, (cm.name?.getD mid).trimAscii.toString, "")
      let cDesc := if isAdm then p.baseUrl else ""
      catalogEntries := catalogEntries.push (s!"custom:{p.id}", p.name, "api_key", cDesc, cModels)
  let provJsons : Array JVal := catalogEntries.map fun (pid, pname, pbilling, pdesc, models) =>
    let mJsons : Array JVal := models.map fun (mid, mname, mdesc) =>
      if mdesc.isEmpty then
        .obj #[("id", .str mid), ("name", .str mname)]
      else
        .obj #[("id", .str mid), ("name", .str mname), ("description", .str mdesc)]
    .obj #[
      ("id", .str pid),
      ("name", .str pname),
      ("billing", .str pbilling),
      ("description", .str pdesc),
      ("models", .arr mJsons)
    ]
  return renderCompact (.obj #[
    ("providers", .arr provJsons),
    ("configured_ids", .arr (configuredIds.map JVal.str))
  ])

/-- Parse `models_json` array into `ProviderTarget` list for `RoutingChain` hydration,
    enriching targets with account & per-model pacing limits from `ai_providers` (and routing
    OAuth/CLIProxy-backed targets through `cliProxyUrl` when `cliProxyKey` is present). -/
def parseChainTargetsJson
    (rawJson : String)
    (providers : Array AIProviderRecord := #[])
    (hydratedProvs : Array HydratedProvider := #[])
    (cliProxyUrl : String := "")
    (cliProxyKey : String := "") : Array ProviderTarget := Id.run do
  match OrbBin.Json.parse rawJson with
  | .ok (.arr items) =>
    let mut out : Array ProviderTarget := #[]
    for it in items do
      let provRaw := (it.fieldStr? "provider_id").orElse (fun _ => it.fieldStr? "provider") |>.getD "openai"
      let strippedProv := if provRaw.startsWith "custom:" then (provRaw.drop 7).toString else provRaw
      let provSlug := providerSlugOf strippedProv
      let defaultAcct :=
        if provRaw.startsWith "custom:" then strippedProv else "default"
      let acctRaw := (it.fieldStr? "account_id").orElse (fun _ => it.fieldStr? "accountId") |>.getD defaultAcct
      let hasExplicitAcct := (it.fieldStr? "account_id").isSome || (it.fieldStr? "accountId").isSome
      let mdlRaw := (it.fieldStr? "model_id").orElse (fun _ => it.fieldStr? "modelId") |>.getD ""
      let inlineUrl? := (it.fieldStr? "base_url").orElse (fun _ => it.fieldStr? "baseUrl") |>.filter (!·.isEmpty)
      let inlineKey? := (it.fieldStr? "api_key").orElse (fun _ => it.fieldStr? "apiKey") |>.filter (!·.isEmpty)
      let matchedHydrated? := hydratedProvs.find? fun hp =>
        hp.enabled && (hp.hasApiKey || hp.hasOAuth) && (
          hp.id == acctRaw ||
          hp.id == strippedProv ||
          (!provRaw.startsWith "custom:" && hp.providerType == provRaw) ||
          (!provSlug.isEmpty && providerSlugOf hp.name == provSlug)
        )
      let matchedProv? := matchProviderForChainTarget? providers acctRaw provRaw
      let anyCfgProv? := providers.find? fun p =>
        p.id == acctRaw || p.id == strippedProv ||
        (!provRaw.startsWith "custom:" && p.providerType == provRaw) ||
        (!provSlug.isEmpty && providerSlugOf p.name == provSlug)
      let effProvType :=
        match matchedHydrated? with
        | some hp => hp.providerType
        | none => match matchedProv? with | some p => p.providerType | none => provRaw
      let isAg := effProvType == "antigravity" || provRaw == "antigravity" || provRaw.startsWith "antigravity:"
      let mdl := if isAg then canonicalAntigravityProxyModelId mdlRaw else mdlRaw
      let matchedModel? := matchedProv?.bind (fun p => p.customModels.find? (fun cm => cm.id == mdl || cm.id == mdlRaw))
      let inlineAcctRpm? := (parseOptionalBoundedU32 it "rpm_limit" 1 100000).toOption.join
      let inlineAcctConc? := (parseOptionalBoundedU32 it "max_concurrency" 1 1024).toOption.join
      let inlineMdlRpm? := (parseOptionalBoundedU32 it "model_rpm_limit" 1 100000).toOption.join
      let inlineMdlTpm? := (parseOptionalBoundedU64 it "model_tpm_limit" 1 1000000000).toOption.join
      let inlineMdlConc? := (parseOptionalBoundedU32 it "model_max_concurrency" 1 1024).toOption.join

      -- When `providers`/`hydratedProvs` are populated (live store hydration) and every matching account is disabled
      -- with no inline credentials, skip this unconfigured/disabled entry instead of emitting an unauthenticated dead target!
      let explicitlyDisabledInStore :=
        (!providers.isEmpty || !hydratedProvs.isEmpty) &&
        inlineKey?.isNone && inlineUrl?.isNone &&
        matchedHydrated?.isNone && matchedProv?.isNone &&
        (anyCfgProv?.map (!·.enabled) |>.getD false) &&
        !isAg
      if !explicitlyDisabledInStore then
        let useCliProxy :=
          !cliProxyKey.isEmpty && !cliProxyUrl.isEmpty && inlineKey?.isNone && inlineUrl?.isNone && (
            isAg ||
            (match matchedHydrated? with
             | some hp => !hp.hasApiKey && hp.hasOAuth
             | none => false)
          )
        if useCliProxy then
          let acct :=
            if hasExplicitAcct then acctRaw
            else match matchedHydrated? with
              | some hp => if isAg then "cliproxyapi:antigravity" else s!"cliproxyapi:{hp.providerType}"
              | none => if isAg then "cliproxyapi:antigravity" else "cliproxyapi"
          out := out.push {
            accountId              := acct
            provider               := provRaw
            baseUrl                := cliProxyUrl
            apiKey                 := cliProxyKey
            modelId                := mdl
            accountRpmLimit?       := inlineAcctRpm?.orElse (fun _ => matchedHydrated?.bind (·.rpmLimit?))
            accountMaxConcurrency? := inlineAcctConc?.orElse (fun _ => matchedHydrated?.bind (·.maxConcurrency?))
            modelRpmLimit?         := inlineMdlRpm?.orElse (fun _ => matchedModel?.bind (·.rpmLimit?))
            modelTpmLimit?         := inlineMdlTpm?.orElse (fun _ => matchedModel?.bind (·.tpmLimit?))
            modelMaxConcurrency?   := inlineMdlConc?.orElse (fun _ => matchedModel?.bind (·.maxConcurrency?))
          }
        else
          let acct :=
            match matchedHydrated? with
            | some hp => hp.id
            | none => match matchedProv? with | some p => p.id | none => acctRaw
          let url :=
            inlineUrl?
            |>.orElse (fun _ => matchedHydrated?.bind (fun hp => if hp.baseUrl.isEmpty then none else some hp.baseUrl))
            |>.orElse (fun _ => matchedProv?.bind (fun p => if p.baseUrl.isEmpty then none else some p.baseUrl))
            |>.getD (defaultProviderBaseUrl effProvType)
          let key :=
            inlineKey?
            |>.orElse (fun _ => matchedHydrated?.bind (fun hp => if hp.apiKey.isEmpty then none else some hp.apiKey))
            |>.orElse (fun _ => matchedProv?.map (·.apiKey))
            |>.getD ""
          if (!providers.isEmpty || !hydratedProvs.isEmpty) && key.isEmpty && inlineUrl?.isNone && !cliProxyKey.isEmpty && !cliProxyUrl.isEmpty then
            -- Fallback to CLIProxyAPI if provider has no direct API key on disk
            out := out.push {
              accountId              := s!"cliproxyapi:{provRaw}"
              provider               := provRaw
              baseUrl                := cliProxyUrl
              apiKey                 := cliProxyKey
              modelId                := mdl
              accountRpmLimit?       := inlineAcctRpm?.orElse (fun _ => matchedProv?.bind (·.rpmLimit?))
              accountMaxConcurrency? := inlineAcctConc?.orElse (fun _ => matchedProv?.bind (·.maxConcurrency?))
              modelRpmLimit?         := inlineMdlRpm?.orElse (fun _ => matchedModel?.bind (·.rpmLimit?))
              modelTpmLimit?         := inlineMdlTpm?.orElse (fun _ => matchedModel?.bind (·.tpmLimit?))
              modelMaxConcurrency?   := inlineMdlConc?.orElse (fun _ => matchedModel?.bind (·.maxConcurrency?))
            }
          else
            out := out.push {
              accountId              := acct
              provider               := provRaw
              baseUrl                := url
              apiKey                 := key
              modelId                := mdl
              accountRpmLimit?       := inlineAcctRpm?.orElse (fun _ => matchedProv?.bind (·.rpmLimit?))
              accountMaxConcurrency? := inlineAcctConc?.orElse (fun _ => matchedProv?.bind (·.maxConcurrency?))
              modelRpmLimit?         := inlineMdlRpm?.orElse (fun _ => matchedModel?.bind (·.rpmLimit?))
              modelTpmLimit?         := inlineMdlTpm?.orElse (fun _ => matchedModel?.bind (·.tpmLimit?))
              modelMaxConcurrency?   := inlineMdlConc?.orElse (fun _ => matchedModel?.bind (·.maxConcurrency?))
            }
    return out
  | _ => return #[]

/-- Hydrate `RoutingChain` table from `missions.db` (`model_routing_chains` + `ai_providers` + decrypted `.sandboxed-sh/ai_providers.json` + CLIProxyAPI). -/
def loadRoutingChainsFromStore (st : CoreStore) (workingDir : String := "") : IO (Array RoutingChain) := do
  let providers ← listAIProviders st
  let effWorkDir := if workingDir.isEmpty then st.rootDir else workingDir
  let hydratedProvs ← loadHydratedProviders st effWorkDir
  let cliKey := ((← lookupEnvWithFiles? "CLI_PROXY_API_KEY").getD "").trimAscii.toString
  let cliUrl ← resolveCliProxyBaseUrl
  let .ok rows ← execParamQuery st.missionsDb "SELECT id,name,models_json FROM model_routing_chains ORDER BY id ASC;" #[]
    | throw (IO.userError "routing_chain_store_unavailable")
  let mut out : Array RoutingChain := #[]
  for i in [1:rows.size] do
    let r := rows[i]!
    let cid := (r[0]?).getD ""
    let nm := (r[1]?).getD cid
    let mj := (r[2]?).getD "[]"
    out := out.push { id := cid, name := nm, targets := parseChainTargetsJson mj providers hydratedProvs cliUrl cliKey }
  -- Immutable defaults are a derived view, not a second mutable config store.
  -- Persisted ids (even empty/unavailable chains) always win over stock entries.
  for (id, name, entries) in OrbCore.ProxyModelRouting.stockChains do
    if !out.any (fun c => c.id == id) then
      out := out.push { id := id, name := name, targets := parseChainTargetsJson (OrbCore.ProxyModelRouting.entriesJson entries) providers hydratedProvs cliUrl cliKey }
  return out

private def optU32Json (v? : Option UInt32) : String :=
  match v? with | some v => s!"{v}" | none => "null"

private def optU64Json (v? : Option UInt64) : String :=
  match v? with | some v => s!"{v}" | none => "null"

/-- Render `ResolvedEntry[]` JSON for `GET /api/model-routing/chains/:id/resolve`. -/
def renderResolvedChainJson (chain : RoutingChain) (pacingTracker? : Option ProxyPacingTracker) : IO String := do
  let mut items : Array String := Array.mkEmpty chain.targets.size
  for tgt in chain.targets do
    let obsRpm? ← match pacingTracker? with
      | some tr => lookupObservedKeyRpm? tr tgt.accountId
      | none => pure none
    let effAcctRpm? := tgt.accountRpmLimit?.orElse (fun _ => obsRpm?)
    let hasCreds := if tgt.apiKey.isEmpty then "false" else "true"
    let authKind := if tgt.apiKey.isEmpty then "\"none\"" else "\"api_key\""
    let hasBaseUrl := if tgt.baseUrl.isEmpty then "false" else "true"
    let entryJson :=
      s!"\{\"provider_id\":{jsonEscape tgt.provider},\"model_id\":{jsonEscape tgt.modelId}," ++
      s!"\"account_id\":{jsonEscape tgt.accountId},\"has_credentials\":{hasCreds}," ++
      s!"\"auth_kind\":{authKind},\"has_base_url\":{hasBaseUrl}," ++
      s!"\"rpm_limit\":{optU32Json effAcctRpm?}," ++
      s!"\"max_concurrency\":{optU32Json tgt.accountMaxConcurrency?}," ++
      s!"\"model_rpm_limit\":{optU32Json tgt.modelRpmLimit?}," ++
      s!"\"model_tpm_limit\":{optU64Json tgt.modelTpmLimit?}," ++
      s!"\"model_max_concurrency\":{optU32Json tgt.modelMaxConcurrency?}}"
    items := items.push entryJson
  return "[" ++ String.intercalate "," items.toList ++ "]"

private def findMatchingRoutingChain? (chains : Array RoutingChain) (m : String) : Option RoutingChain :=
  OrbCore.ProxyModelRouting.storedChain? chains m

/-- Resolve direct model ids through the same account/limit hydration as saved
    chains. Unknown bare names do not become CLIProxy model ids or default routes. -/
private def directRoutingChain? (st : CoreAppState) (chains : Array RoutingChain)
    (requested path : String) : IO (Option RoutingChain) := do
  let providers ← listAIProviders st.store
  let mut customModels : Array (String × String) := #[]
  for p in providers do
    if p.providerType == "custom" then
      let name := OrbCore.ProxyModelRouting.customProviderName p.name
      for model in p.customModels do customModels := customModels.push (name, model.id)
  -- Preserve successful discovery membership without contacting an upstream.
  for fp in #[s!"{st.store.rootDir}/model-discovery.json", s!"{st.cfg.workingDir}/.sandboxed-sh/model-discovery.json"] do
    if let some raw ← (try some <$> IO.FS.readFile fp catch _ => pure none) then
      if let .ok discovery := OrbBin.Json.parse raw then
        if discovery.fieldNat? "schema_version" == some 1 then
          for observation in (discovery.fieldArr? "connections").getD #[] do
            let pid := (observation.fieldStr? "provider_id").getD ""
            for p in providers do
              let name := OrbCore.ProxyModelRouting.customProviderName p.name
              if p.providerType == "custom" && (pid == name || pid == p.id || pid == s!"custom:{p.id}") then
                let success := observation.fieldOrNull "last_success"
                let models := (success.fieldArr? "models").getD #[]
                let fallback := if success.isNull || success.fieldStr? "completeness" == some "partial" then
                    (observation.fieldArr? "fallback_models").getD #[] else #[]
                for model in models ++ fallback do
                  if let some id := model.fieldStr? "id" then customModels := customModels.push (name, id)
  let some (provider, model) := OrbCore.ProxyModelRouting.directEntry? requested path customModels
    | return none
  let hydrated ← loadHydratedProviders st.store st.cfg.workingDir
  let cliKey := ((← lookupEnvWithFiles? "CLI_PROXY_API_KEY").getD "").trimAscii.toString
  let cliUrl ← resolveCliProxyBaseUrl
  let targets := (parseChainTargetsJson (OrbCore.ProxyModelRouting.entriesJson #[(provider, model)])
    providers hydrated cliUrl cliKey).filter (fun t => !t.apiKey.isEmpty)
  -- Explicit in-memory chain snapshots can be the configured standard accounts
  -- (including hermetic transports). Do not resurrect them over disabled store rows.
  let hasConfiguredOwner := providers.any (fun p => p.providerType == provider || p.id == provider ||
      (p.providerType == "custom" && OrbCore.ProxyModelRouting.customProviderName p.name == provider)) ||
    hydrated.any (fun p => p.providerType == provider || p.id == provider)
  let targets := if targets.isEmpty && !hasConfiguredOwner then
      (chains.flatMap (·.targets)).filter (fun t =>
        t.provider == provider && t.modelId == model && !t.apiKey.isEmpty)
    else targets
  -- Structural guarantee: a direct route can only carry the requested model.
  let keep := fun (t : ProviderTarget) =>
    t.modelId == model || t.modelId == canonicalAntigravityProxyModelId model
  return some { id := requested, name := requested, targets := targets.filter keep }

private def selectRoutingChainForBody (chains : Array RoutingChain) (body : ByteArray) : RoutingChain :=
  let reqModel? :=
    (String.fromUTF8? body).bind fun raw =>
      match OrbBin.Json.parse raw with
      | .ok jv => jv.fieldStr? "model"
      | .error _ => none
  match reqModel?.bind (findMatchingRoutingChain? chains) with
  | some matched => matched
  | none =>
    (chains.find? (fun c => c.id == "default" || c.id == "builtin/smart")).getD
      (chains[0]?.getD { id := "default", name := "default", targets := #[] })

private def scopeRankOf? : String → Option UInt8
  | "ops_read"       => some 0
  | "service_deploy" => some 1
  | "root_exec" | "host_admin" => some 2
  | _                => none

private def normalizeTargetHost (h : String) : String :=
  let low := h.trimAscii.toString.toLower
  if low == "local" || low == "localhost" || low == "local-node" || low == "self" then "self"
  else h.trimAscii.toString

private def hash64Fnv1a (s : String) : UInt64 := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for b in s.toUTF8.toList do
    h := (h ^^^ b.toUInt64) * 1099511628211
  return if h == 0 then 1 else h

/-- Render `GET /api/health` response body matching exact CI & client contract. -/
def renderHealthJson (cfg : CoreConfig) (hasDbMultiUsers : Bool := false) : String :=
  let authReq := !cfg.devMode
  let authMode :=
    if cfg.devMode then "disabled"
    else if hasDbMultiUsers || !(parseConfiguredUsers cfg.usersJson).isEmpty then "multi_user"
    else "single_tenant"
  let ghEnabled := !cfg.githubClientId.isEmpty
  let libVal := if cfg.libraryRemote.isEmpty then "null" else jsonEscape cfg.libraryRemote
  let devStr := if cfg.devMode then "true" else "false"
  let authStr := if authReq then "true" else "false"
  let ghStr := if ghEnabled then "true" else "false"
  s!"\{\"status\":\"ok\",\"version\":\"0.7.10\",\"dev_mode\":{devStr},\"auth_required\":{authStr},\"auth_mode\":{jsonEscape authMode},\"max_iterations\":{cfg.maxIterations},\"library_remote\":{libVal},\"github_enabled\":{ghStr},\"dashboard_github_login_enabled\":{ghStr},\"github_oauth_client_state\":true}"

private def hasMultipleActiveUsers (st : CoreStore) : IO Bool := do
  match ← execParamQuery st.missionsDb "SELECT COUNT(*) FROM users WHERE disabled=0;" #[] with
  | .ok rows => return (((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 1
  | .error _ => return false

private def clampControlSpendU32 (v : UInt64) : UInt32 :=
  if v > 0xFFFFFFFF then 0xFFFFFFFF else v.toUInt32

/-- Authorize an `admin`-only operation (`opClass = 1`) via `Orb.Kernel.multiuserRbacStep`. -/
private def requireAdminPrincipal (caller : CallerPrincipal) : Option (Nat × String) :=
  let disFlag : UInt8 := if caller.disabled then 1 else 0
  let roleCode : UInt8 := if caller.role == "admin" then 1 else 0
  let rbacWord := Orb.Kernel.multiuserRbacStep 1 disFlag 1 roleCode 1 0 0
  if (rbacWord &&& 1) == 1 then
    none
  else
    let status := ((rbacWord >>> 1) &&& 0xFFFF).toNat
    some (if status == 0 then 403 else status, "{\"error\":\"admin_required\"}")

/-- Authorize a mission read/collaborate (`ownerMutate = false`, `opClass = 2`) or owner-only
    mutation (`ownerMutate = true`, `opClass = 3`) via `Orb.Kernel.multiuserRbacStep`.
    - Returns `404` when the mission does not exist OR when the caller is neither owner nor shared
      participant (even if `caller.role == "admin"` — strict non-disclosure!).
    - Returns `403` when a shared participant attempts an owner-only mutation (`ownerMutate == true`). -/
private def authorizeMissionOp
    (st : CoreAppState)
    (caller : CallerPrincipal)
    (missionId : String)
    (ownerMutate : Bool) : IO (Option (Nat × String)) := do
  if caller.isLegacyUnscoped then
    return none
  let (exists_, isOwner, isPart) ← getMissionRelationship st.store missionId caller.userId
  if !exists_ then
    return some (404, "{\"error\":\"mission_not_found\"}")
  let disFlag : UInt8 := if caller.disabled then 1 else 0
  let roleCode : UInt8 := if caller.role == "admin" then 1 else 0
  let opClass : UInt8 := if ownerMutate then 3 else 2
  let rbacWord := Orb.Kernel.multiuserRbacStep
    1 disFlag 1 roleCode opClass (if isOwner then 1 else 0) (if isPart then 1 else 0)
  if (rbacWord &&& 1) == 1 then
    return none
  let status := ((rbacWord >>> 1) &&& 0xFFFF).toNat
  if status == 403 then
    return some (403, "{\"error\":\"owner_required\"}")
  else
    return some (404, "{\"error\":\"mission_not_found\"}")

/-- Classify placement `(targetKind, nodeAdminOnly)` for `Orb.Kernel.placementRoleAdmit`:
    `0` = Core host/container, `1` = colocated Core node (`sepolia` / `agent-core`),
    `2` = dedicated fleet node, `3` = managed ephemeral VM (`auto-managed*` / `managed-*` / `managed_vm`),
    `4` = client-local (`orb-locald`). -/
private def classifyMissionPlacementTarget
    (clientPlaced : Bool)
    (placeKind : String)
    (remoteNodeId? : Option String)
    (tags : Array String := #[]) : UInt8 × UInt8 :=
  if clientPlaced || placeKind == "client" then
    (4, 0)
  else
    let tagNode? := (tags.find? (fun t => t.startsWith "remote-node:")).map (fun t => (t.drop 12).toString)
    let effNode := (remoteNodeId?.orElse (fun _ => tagNode?) |>.getD "").trimAscii.toString.toLower
    if placeKind == "managed_vm" || placeKind.startsWith "managed-" ||
       effNode == "auto-managed" || effNode.startsWith "auto-managed:" || effNode.startsWith "managed-" then
      (3, 0)
    else if effNode.isEmpty || effNode == "local" || effNode == "core" || effNode == "self" then
      (0, 1)
    else if effNode == "orb-core" || effNode == "agent-core" || effNode == "sepolia" || effNode.endsWith "-core" ||
            tags.any (fun t => t == "admin_only") then
      (1, 1)
    else
      (2, 0)

/-- Enforce `Orb.Kernel.placementRoleAdmit` for `caller` launching/transferring/forking onto `(targetKind, nodeAdminOnly)`. -/
private def checkPlacementForCaller
    (caller : CallerPrincipal)
    (targetKind nodeAdminOnly : UInt8) : Option (Nat × String) :=
  if caller.isLegacyUnscoped then
    none
  else
    let roleCode : UInt8 := if caller.role == "admin" then 1 else 0
    let validUx : UInt8 :=
      match caller.unixUsername? with
      | some ux => if validUnixUsername ux then 1 else 0
      | none => 0
    if Orb.Kernel.placementRoleAdmit roleCode targetKind nodeAdminOnly validUx == 1 then
      none
    else if roleCode == 0 && (targetKind == 0 || targetKind == 1 || nodeAdminOnly != 0) then
      some (403, "{\"error\":\"core_target_forbidden_for_member\",\"message\":\"Core and colocated admin nodes are restricted to admin accounts.\"}")
    else
      some (403, "{\"error\":\"unix_username_required\",\"message\":\"A valid Linux unix_username is required to run remote missions.\"}")

private def renderUserSummaryJson (u : UserRecord) (spentTodayCents : UInt64 := 0) (includeSpent : Bool := false) : String :=
  let unixJson := match u.unixUsername? with | some ux => jsonEscape ux | none => "null"
  let capJson := match u.dailySpendCapCents? with | some c => s!"{c}" | none => "null"
  let spentField := if includeSpent then s!",\"spent_today_cents\":{spentTodayCents}" else ""
  s!"\{\"id\":{jsonEscape u.id},\"username\":{jsonEscape u.username},\"role\":{jsonEscape u.role},\"unix_username\":{unixJson},\"daily_spend_cap_cents\":{capJson}{spentField}}"

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
  | 413 => "Payload Too Large"
  | 422 => "Unprocessable Entity"
  | 429 => "Too Many Requests"
  | 502 => "Bad Gateway"
  | 503 => "Service Unavailable"
  | _   => "Internal Server Error"

def isAllowedCorsOrigin (devMode : Bool) (origin : String) : Bool :=
  let t := origin.trimAscii.toString
  if t.isEmpty then false
  else if t == "null" || t == "orb://localhost" || t == "tauri://localhost" then true
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

def encodeCoreHttpResponse (r : CoreHttpResponse) (keepAlive : Bool := false) : ByteArray := Id.run do
  let corsHdr :=
    match r.corsOrigin? with
    | some orig =>
      if orig.toList.any (fun c => c == '\r' || c == '\n' || c.toNat == 0) then ""
      else
        s!"Access-Control-Allow-Origin: {orig}\r\n" ++
        "Vary: Origin\r\n" ++
        "Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key, X-Paloma-Approval, X-Orb-Token, X-Orb-Lease, X-Language, Last-Event-ID, Cache-Control, Accept\r\n" ++
        "Access-Control-Expose-Headers: X-Orb-Events-Protocol, X-Has-More, X-Next-Cursor, X-Page-Max-Sequence, X-Max-Sequence, Content-Disposition, Retry-After, X-Request-Id\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n"
    | none => ""
  let connHdr :=
    if keepAlive then "Connection: keep-alive\r\nKeep-Alive: timeout=15, max=64\r\n"
    else "Connection: close\r\n"
  let mut head :=
    s!"HTTP/1.1 {r.status} {reasonPhrase r.status}\r\n" ++
    s!"Content-Type: {r.contentType}\r\n" ++
    s!"Content-Length: {r.body.size}\r\n" ++
    corsHdr ++
    connHdr
  for (k, v) in r.extraHdrs do
    if let some ln := safeHeaderLine? k v then
      head := head ++ ln
  head := head ++ "\r\n"
  return head.toUTF8 ++ r.body

private def acceptsGzipEncoding (hdrs : Array (String × String)) : Bool :=
  match lookupHeaderCI hdrs "accept-encoding" with
  | none => false
  | some raw =>
    (raw.splitOn ",").any fun item =>
      let tok := item.trimAscii.toString.toLower
      (tok == "gzip" || tok.startsWith "gzip;") && !(tok.splitOn "q=0").any (fun s => s == "" || s.startsWith ",")

private def headerRequestsClose (hdrs : Array (String × String)) : Bool :=
  match lookupHeaderCI hdrs "connection" with
  | none => false
  | some raw => (raw.splitOn ",").any (fun t => t.trimAscii.toString.toLower == "close")

def maybeGzipHttpResponse (req : HttpRequest) (r : CoreHttpResponse) : CoreHttpResponse :=
  if req.method == "HEAD" || (r.status != 200 && r.status != 201) || r.body.size < 1024 then
    r
  else if !acceptsGzipEncoding req.headers then
    r
  else if r.extraHdrs.any (fun (k, _) => k.toLower == "content-encoding") then
    r
  else
    let gz := OrbNetLeaf.Gzip.gzipCompress r.body
    if gz.size < r.body.size then
      { r with
        body := gz
        extraHdrs := r.extraHdrs ++ #[("Content-Encoding", "gzip"), ("Vary", "Accept-Encoding")]
      }
    else
      r

def jsonResponse (status : Nat) (bodyStr : String) (extraHdrs : Array (String × String) := #[])
    (corsOrigin? : Option String := none) : CoreHttpResponse :=
  { status := status, contentType := "application/json", corsOrigin? := corsOrigin?, extraHdrs := extraHdrs, body := bodyStr.toUTF8 }

private def isWsUpgradePath (cleanPath rawTarget : String) : Bool :=
  cleanPath == "/api/console/ws" ||
  cleanPath == "/api/monitoring/ws" ||
  cleanPath == "/api/control/sync" ||
  cleanPath == "/api/desktop/stream" ||
  (matchRoutePattern? "/api/workspaces/:id/shell" rawTarget).isSome

private def negotiateWsSubprotocol? (hdrs : Array (String × String)) : Option String :=
  match lookupHeaderCI hdrs "sec-websocket-protocol" with
  | none => none
  | some raw =>
    let parts := (raw.splitOn ",").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    if parts.contains "orb-sync.v1" then
      some "orb-sync.v1"
    else
      parts.find? (·.startsWith "jwt.")

private def nextUniqueId (st : CoreAppState) (prefixStr : String) (nowEpochSec : UInt64) : IO String := do
  let seq ← st.seqRef.modifyGet fun n => (n + 1, n + 1)
  return s!"{prefixStr}-{nowEpochSec}-{seq}"

private def hex12OfU64 (v : UInt64) : String := Id.run do
  let hex := "0123456789abcdef".toList.toArray
  let mut chars : Array Char := Array.mkEmpty 12
  for i in [0:12] do
    let shift := ((11 - i) * 4).toUInt64
    let nib := ((v >>> shift) &&& 0xF).toNat
    chars := chars.push hex[nib]!
  return String.ofList chars.toList

private def nextMcpSessionUuid (st : CoreAppState) : IO String := do
  let seq ← st.seqRef.modifyGet fun n => (n + 1, n + 1)
  return s!"00000000-0000-4000-8000-{hex12OfU64 seq}"

private def bodyHasImages (jv : JVal) : Bool :=
  match jv.fieldArr? "attachments" with
  | none => false
  | some xs => xs.any fun item =>
      let kind := (item.fieldStr? "kind").getD ""
      let mime := (item.fieldStr? "mime_type").getD ((item.fieldStr? "content_type").getD "")
      kind == "image" || mime.startsWith "image/"

private def isClientPlacement (placement? : Option String) (tags : Array String) : Bool :=
  (placement?.map (fun p => p == "client" || p.startsWith "client:")).getD false ||
  tags.any (fun t => t == "placement:client" || t.startsWith "placement:client:")

private def isMissionIdleForCyberChange (st : CoreAppState) (m : MissionRecord) : IO Bool := do
  if !isStatusMovable m.status then
    return false
  match ← execParamQuery st.store.missionsDb
      "SELECT COUNT(*) FROM mission_runs WHERE mission_id=?1 AND execution_state<>'terminal';" #[m.id] with
  | .error _ => return false
  | .ok rs => return (((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 1) == 0

private def targetSupportsExplicitCyber (tgt : ProviderTarget) (requestedModel cleanPath : String) : Bool :=
  let fullUrl := trimTrailingSlashes tgt.baseUrl.trimAscii.toString ++ cleanPath
  let preservesModel := tgt.modelId.isEmpty || bareModel tgt.modelId == requestedModel
  preservesModel && cyberEntrySupported tgt.provider requestedModel fullUrl tgt.apiKey false false

/-- Settings as returned to clients: no password hash and no Bitwarden token in any of its spellings. -/
private def redactSettingsSecrets (settings : JVal) : JVal :=
  let base := (settings.removeField "password_hash").removeField "bws_access_token"
  match base.field? "bitwarden" with
  | some bw => base.setField "bitwarden" ((bw.removeField "encrypted_access_token").removeField "access_token")
  | none => base

/-- Gate `/v1/*` proxy requests against execution-bound mission Cyber selections (`#1497`)
    and per-account cooldowns (`#1612`). -/
private def handleProxyRequest (st : CoreAppState) (req : HttpRequest) (cleanPath : String)
    (reqOrigin? : Option String) (nowEpochSec : UInt64) : IO CoreHttpResponse := do
  let mkJson (code : Nat) (b : String) : CoreHttpResponse := jsonResponse code b #[] reqOrigin?
  let mkJsonHdr (code : Nat) (b : String) (hdrs : Array (String × String)) : CoreHttpResponse :=
    jsonResponse code b hdrs reqOrigin?
  let bodyStr := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
  let bodyJv := (OrbBin.Json.parse bodyStr).toOption.getD (.obj #[])
  let requestedModel := bareModel ((bodyJv.fieldStr? "model").getD defaultCodexModel)
  let execKey? := lookupHeaderCI req.headers "x-sandboxed-execution-key"
  let mut selection? : Option Selection := none
  let mut boundMid? : Option String := none
  if let some key := execKey? then
    if !key.startsWith "remote-launch:" then
      return mkJson 403 "{\"error\":\"invalid_access_program\",\"detail\":\"This mission execution key is stale\"}"
    let mid := (key.drop 14).toString
    if !isSafeMissionId mid then
      return mkJson 403 "{\"error\":\"invalid_access_program\",\"detail\":\"invalid_mission_id\"}"
    let some _ ← getMission? st.store mid
      | return mkJson 403 "{\"error\":\"invalid_access_program\",\"detail\":\"This mission execution key is stale\"}"
    boundMid? := some mid
    match ← readCommittedSelection st.cfg.workingDir mid with
    | .error e => return mkJson 403 s!"\{\"error\":\"invalid_access_program\",\"detail\":{jsonEscape e}}"
    | .ok sel =>
      if sel.revision != nilRevision then
        match ← readBinding? st.cfg.workingDir mid with
        | none => return mkJson 403 "{\"error\":\"invalid_access_program\",\"detail\":\"This mission execution key is stale\"}"
        | some b =>
          if b.key != key || b.revision != sel.revision then
            return mkJson 403 "{\"error\":\"invalid_access_program\",\"detail\":\"This mission execution key is stale\"}"
          if bareModel b.model != requestedModel then
            return mkJson 400 "{\"error\":\"invalid_access_program\",\"detail\":\"The execution key is bound to another model\"}"
      selection? := some sel
  let headerProgram? := lookupHeaderCI req.headers "x-sandboxed-cyber-program"
  let bodyProgram? := bodyCyberProgram? bodyStr
  let expected? ← match enforceProxySelection selection? requestedModel headerProgram? bodyProgram? with
    | .ok p => pure p
    | .error e => return mkJson 400 s!"\{\"error\":\"unsupported_access_program\",\"detail\":{jsonEscape e}}"
  let snapRouteGen? ← match st.healthTracker? with
    | some htr => some <$> currentRouteGeneration htr
    | none => pure none
  let mut proxyOwnerUserId? : Option String := none
  if let some pTok := extractProxyToken? req.headers nowEpochSec then
    if pTok.startsWith "orb-mpt-v1_" then
      if let some (mptMid, mptOwnerUid) ← resolveMissionProxyToken? st.store pTok nowEpochSec then
        if !mptOwnerUid.isEmpty then proxyOwnerUserId? := some mptOwnerUid
        if boundMid?.isNone then boundMid? := some mptMid
    else if pTok.startsWith "orb-jwt-v2:" then
      if let some (uid, _, tokEp, _) := verifySessionTokenV2 (effectiveJwtSecret st.cfg) pTok nowEpochSec then
        if let some u ← getUserById? st.store uid then
          if !u.disabled && u.sessionEpoch == tokEp then
            proxyOwnerUserId? := some u.id
  let utcDay := currentUtcDay nowEpochSec
  let mut userPrefs : Array (String × Bool) := #[]
  if let some ownerUid := proxyOwnerUserId? then
    let some ownerRec ← getUserById? st.store ownerUid
      | return mkJson 401 "{\"error\":\"unauthorized_proxy_owner\"}"
    if ownerRec.disabled then
      return mkJson 401 "{\"error\":\"account_disabled\"}"
    userPrefs ← getUserProviderPrefs st.store ownerUid
    let (infSpent, cmpSpent) ← getUserSpentTodayCents st.store ownerUid utcDay
    let userSpent := infSpent + cmpSpent
    let mf ← st.managedRef.get
    let globalActive : UInt8 := if mf.enabled then 1 else 0
    let userActive : UInt8 := if ownerRec.dailySpendCapCents?.isSome then 1 else 0
    let userCapU32 : UInt32 := clampControlSpendU32 (ownerRec.dailySpendCapCents?.getD 0)
    if globalActive == 1 || userActive == 1 then
      let capWord := Orb.Kernel.userSpendCapStep
        globalActive (clampControlSpendU32 mf.spentTodayCents) (clampControlSpendU32 mf.dailyCapCents)
        userActive (clampControlSpendU32 userSpent) userCapU32
        1
      if (capWord &&& 1) != 1 then
        let denyReason := ((capWord >>> 1) &&& 0x7).toNat
        let scopeStr := if denyReason == 2 then "user" else "global"
        return mkJson 429 s!"\{\"error\":\{\"type\":\"spend_cap_exceeded\",\"code\":\"daily_spend_cap_exceeded\",\"scope\":{jsonEscape scopeStr},\"message\":\"Daily spend cap reached\"}}"
  let rawRequestedModel := (bodyJv.fieldStr? "model").getD defaultCodexModel
  let chains ← st.chainsRef.get
  -- A named model is served by its saved chain or by the provider owning that
  -- exact model. It is NEVER rewritten to another model: only a chain the caller
  -- named may fall back across models. Only a request with no `model` field
  -- keeps the default chain.
  let mut routed? : Option RoutingChain := none
  let mut routeKind := "chain"
  if (bodyJv.fieldStr? "model").isNone then
    routed? := some (selectRoutingChainForBody chains req.bodySlice.toByteArray)
    routeKind := "default"
  else
    match findMatchingRoutingChain? chains rawRequestedModel with
    | some matched => routed? := some matched
    | none =>
      routed? ← directRoutingChain? st chains rawRequestedModel cleanPath
      routeKind := "direct"
      if routed?.isNone then
        -- The in-memory snapshot can predate a chain saved by another path (import,
        -- another process). Look at the store once before refusing a name.
        let fresh ← loadRoutingChainsFromStore st.store st.cfg.workingDir
        if let some matched := findMatchingRoutingChain? fresh rawRequestedModel then
          discard <| publishRoutingChainsUpdate st fresh (forceBump := false)
          routed? := some matched
          routeKind := "chain"
  let some rawActiveChain := routed?
    | return mkJson 400 (OrbCore.ProxyModelRouting.unknownModelBody rawRequestedModel)
  if routeKind == "direct" && rawActiveChain.targets.isEmpty then
    return mkJson 503 (OrbCore.ProxyModelRouting.noProviderBody rawRequestedModel)
  let activeChain := filterChainTargetsForUserPrefs rawActiveChain userPrefs
  if proxyOwnerUserId?.isSome && !rawActiveChain.targets.isEmpty && activeChain.targets.isEmpty then
    return mkJson 403 "{\"error\":\"no_user_enabled_providers\",\"message\":\"All configured inference providers for this model are disabled in your preferences.\"}"
  let proxySecretBearer :=
    !st.cfg.proxySecret.isEmpty &&
    match extractBearerToken? req.headers nowEpochSec with
    | some tok => ctEqSlice (ByteSlice.ofString tok) (ByteSlice.ofString st.cfg.proxySecret)
    | none => false
  let headersAlreadyCommitted :=
    proxySecretBearer &&
    ((lookupHeaderCI req.headers "x-orb-first-byte-committed").map (fun v =>
      let low := v.trimAscii.toString.toLower
      low == "1" || low == "true") |>.getD false)
  let explicitAttemptGen? : Option UInt64 :=
    if proxySecretBearer then
      (lookupHeaderCI req.headers "x-orb-attempt-generation").bind (fun v =>
        (v.trimAscii.toString.toNat?).map Nat.toUInt64)
    else
      none
  let attemptGen? : Option UInt64 := explicitAttemptGen?.orElse (fun _ => snapRouteGen?)
  let pinnedAcctHdr :=
    if proxySecretBearer then
      (lookupHeaderCI req.headers "x-orb-pinned-account").map (·.trimAscii.toString) |>.getD ""
    else
      ""
  let plan ← match st.healthTracker? with
    | some htr =>
      let hPlan ← planChainFromHealth htr activeChain nowEpochSec
      let extra := activeCooldowns (← st.proxyCooldownsRef.get) nowEpochSec
      if extra.isEmpty then
        pure hPlan
      else
        let mergedCooling := coolingFor activeChain.targets (hPlan.cooling ++ extra)
        pure { eligible := capProxyTargets (eligibleTargets activeChain.targets mergedCooling), cooling := mergedCooling }
    | none =>
      let cooldowns ← st.proxyCooldownsRef.get
      pure (planChain activeChain cooldowns nowEpochSec)
  if !headersAlreadyCommitted && plan.eligible.isEmpty && !plan.cooling.isEmpty then
    if plan.allUsageLimited then
      let limit := (soonestCooldown? plan.cooling).getD
        { accountId := "", untilEpoch := nowEpochSec + 60, reason := .usageLimit, label := "" }
      let reply := usageLimitReply activeChain.id limit nowEpochSec
      return mkJsonHdr reply.status reply.body reply.headers
    let retryAfter := (plan.retryAfterSecs? nowEpochSec).getD 60
    let reply := cooldownReply activeChain.id retryAfter
    return mkJsonHdr reply.status reply.body reply.headers
  let effectiveChain ←
    if expected?.isSome then
      match plan.eligible[0]?.orElse (fun _ => activeChain.targets[0]?) with
      | none => return mkJson 400 "{\"error\":\"unsupported_access_program\",\"detail\":\"no upstream route\"}"
      | some tgt =>
        if !targetSupportsExplicitCyber tgt requestedModel cleanPath then
          return mkJson 400 "{\"error\":\"unsupported_access_program\"}"
        pure { activeChain with targets := activeChain.targets.filter (fun t => targetSupportsExplicitCyber t requestedModel cleanPath) }
    else
      pure activeChain
  let dispatchChain : RoutingChain :=
    if headersAlreadyCommitted && !pinnedAcctHdr.isEmpty then
      let pinnedFirst := effectiveChain.targets.filter (fun t => t.accountId == pinnedAcctHdr)
      let others := effectiveChain.targets.filter (fun t => t.accountId != pinnedAcctHdr)
      { effectiveChain with targets := pinnedFirst ++ others }
    else
      effectiveChain
  let forwardBody ← match expected? with
    | none => pure req.bodySlice.toByteArray
    | some program =>
      match injectAccessProgram req.bodySlice.toByteArray program with
      | .ok b => pure b
      | .error e => return mkJson 400 s!"\{\"error\":\"unsupported_access_program\",\"detail\":{jsonEscape e}}"
  let skipAccountIds := if headersAlreadyCommitted then #[] else plan.cooling.map (fun c => c.accountId)
  let explicitPinned? : Option String :=
    if headersAlreadyCommitted then some pinnedAcctHdr else none
  let out ← forwardProxyChain dispatchChain req.method cleanPath #[] forwardBody
    st.proxyMockTransport? headersAlreadyCommitted st.pacingTracker?
    (skipAccountIds := skipAccountIds)
    (healthTracker? := st.healthTracker?)
    (attemptGeneration? := attemptGen?)
    (nowEpoch? := some nowEpochSec)
    (pinnedAccount? := explicitPinned?)
  match st.healthTracker? with
  | some htr =>
    let active ← snapshotActiveHealthCooldowns htr nowEpochSec
    st.proxyCooldownsRef.set active
  | none =>
    let cooldowns ← st.proxyCooldownsRef.get
    let stillActive := activeCooldowns cooldowns nowEpochSec
    let withoutSelected := stillActive.filter (fun c => c.accountId != out.selectedAccount)
    let refreshed :=
      match cooldownForOutcome out nowEpochSec with
      | some c => withoutSelected.push c
      | none => withoutSelected
    st.proxyCooldownsRef.set refreshed
  if out.status ≥ 200 && out.status < 300 then
    if let some ownerUid := proxyOwnerUserId? then
      let estCents := estimateProxyUsageCostCents out.headers out.body
      if estCents > 0 then
        discard <| addUserSpendCents st.store ownerUid utcDay estCents 0 s!"{nowEpochSec}"
    let usedTarget? := dispatchChain.targets.find? (fun t => t.accountId == out.selectedAccount)
    let usedMissionId := boundMid?.getD ""
    let callerKind ←
      if usedMissionId.isEmpty then pure "api"
      else do
        let parent := ((← getMission? st.store usedMissionId).map (·.parentMissionId)).getD ""
        pure (if parent.isEmpty then "mission" else "subagent")
    recordProxyUsage st.store nowEpochSec
      ((usedTarget?.map (·.modelId)).getD requestedModel) ((usedTarget?.map (·.provider)).getD "")
      out.selectedAccount (execKey?.getD "") usedMissionId callerKind (extractProxyUsage out.body)
      (requestedModel := rawRequestedModel)
  if let (some program, some mid, some sel) := (expected?, boundMid?, selection?) then
    let text := String.fromUTF8? out.body |>.getD ""
    for line in text.splitOn "\n" do
      let t := line.trimAscii.toString
      if t.startsWith "data:" then
        let data := (t.drop 5).toString.trimAscii.toString
        if let some (confirmed, model) := observeSseData? data program then
          discard <| writeReceipt st.cfg.workingDir mid {
            revision := sel.revision, requestedModel := requestedModel, program := confirmed, model := model
          }
  let servedTarget? := dispatchChain.targets.find? (fun t => t.accountId == out.selectedAccount)
  let effectiveModel := (servedTarget?.map (·.modelId)).filter (!·.isEmpty) |>.getD rawRequestedModel
  discard <| execParamQuery st.store.missionsDb
    ("INSERT INTO proxy_outcomes(timestamp,chain_id,provider,account_id,model,requested_model,status,http_status,retries) " ++
     "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);")
    #[formatEpochIso8601Utc nowEpochSec, (if routeKind == "chain" then dispatchChain.id else routeKind),
      (servedTarget?.map (·.provider)).getD "", out.selectedAccount, effectiveModel, rawRequestedModel,
      (if out.status ≥ 200 && out.status < 300 then "ok" else "error"), toString out.status,
      toString (out.attemptsUsed - 1)]
  let diagHdrs := out.headers ++ #[
    ("X-Orb-Requested-Model", rawRequestedModel),
    ("X-Orb-Effective-Model", effectiveModel),
    ("X-Orb-Route", if routeKind == "chain" then s!"chain:{dispatchChain.id}" else routeKind),
    ("X-Orb-Selected-Account", out.selectedAccount),
    ("X-Orb-Attempts-Used", s!"{out.attemptsUsed}"),
    ("X-Orb-Verdict-Code", s!"{out.verdictCode}"),
    ("X-Orb-First-Byte-Committed", if out.firstByteCommitted then "true" else "false")
  ]
  return { status := out.status, contentType := out.contentType, corsOrigin? := reqOrigin?, extraHdrs := diagHdrs, body := out.body }

/-- Map structured `HarnessCallbacks` from `OrbBin.ClaudeControl` onto persisted `mission_events` rows
    and record pending `control_request` call IDs so `POST /api/control/tool_result` can route answers cleanly. -/
def buildCoreHarnessCallbacks (st : CoreAppState) (missionId : String) : OrbBin.ClaudeControl.HarnessCallbacks := {
  onStructuredEvent := fun evType payload => do
    let nowSec ← coreEpochSec
    let ts := formatEpochIso8601Utc nowSec
    if evType == "tool_call" then
      let cid := (payload.fieldStr? "tool_call_id").getD ""
      let nm := (payload.fieldStr? "name").getD "tool"
      let args := (payload.field? "args").getD (.obj #[])
      if nm == "ui_native_request" && !cid.isEmpty then
        if let some ref := st.pendingControlCallsRef? then
          ref.modify fun xs =>
            let trimmed := if xs.size ≥ 512 then xs.extract 1 xs.size else xs
            (trimmed.filter (fun p => p.1 != cid)).push (cid, missionId)
      let pl := renderCompact (.obj #[("tool_call_id", .str cid), ("tool_name", .str nm), ("args", args)])
      discard <| appendMissionEvent st.store missionId "tool_call" pl ts
    else
      discard <| appendMissionEvent st.store missionId evType (renderCompact payload) ts
  onTurnFinished := fun finalSnap => do
    let nowSec ← coreEpochSec
    let ts := formatEpochIso8601Utc nowSec
    if let some sid := finalSnap.sessionId?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
      discard <| execParamQuery st.store.missionsDb
        "UPDATE missions SET session_id=?2, resumable=1 WHERE id=?1;" #[missionId, sid]
    let isErr := finalSnap.error?.isSome || (finalSnap.exitCode?.getD 0) != 0
    let mut armedWakeups : Nat := 0
    let mut isSideQ := false
    if !isErr then
      if let .ok cRows ← execParamQuery st.store.missionsDb
          "SELECT COUNT(*) FROM mission_continuations WHERE mission_id=?1 AND phase=1;" #[missionId] then
        if cRows.size > 1 then armedWakeups := ((cRows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
      if let .ok tRows ← execParamQuery st.store.missionsDb
          "SELECT COALESCE(tags,'[]') FROM missions WHERE id=?1;" #[missionId] then
        let tRaw := (tRows[1]?.bind (·[0]?)).getD "[]"
        isSideQ := (tRaw.splitOn "\"side-question\"").length > 1
    -- Exit 0 with no text and no tool call is not a finished turn: retry, then fail.
    let emptyVerdict? ←
      if !isErr && finalSnap.text.trimAscii.toString.isEmpty then
        OrbCore.RemoteDispatch.settleEmptyTurn st.store st.broadcastHub? missionId ts nowSec (retryable := !isSideQ)
      else pure none
    let nextStatus :=
      if let some verdict := emptyVerdict? then verdict
      else if isErr then "failed"
      else if armedWakeups > 0 then "awaiting_user"
      else if isSideQ then "completed"
      else "awaiting_user"
    discard <| execParamQuery st.store.missionsDb
      "UPDATE missions SET status=?2,state_revision=state_revision+1,updated_at=?3 WHERE id=?1 AND status IN ('active','pending');"
      #[missionId, nextStatus, ts]
    let stPl := renderCompact (.obj #[("status", .str nextStatus), ("content", .str finalSnap.text)])
    discard <| appendMissionEvent st.store missionId "mission_status_changed" stPl ts
    publishControlEvent st.broadcastHub? "mission_status_changed" stPl (some missionId)
}

/-- Resolve a confined git workspace directory for a non-client mission under `st.cfg.workingDir`. -/
private def resolveConfinedCoreMissionGitDir (st : CoreAppState) (m : MissionRecord) : IO (Except (Nat × String) String) := do
  if m.placementKind == "client" then
    return .error (400, "{\"error\":\"client_mission_uses_local_git\"}")
  match ← confineWorkingDirectory st.cfg.workingDir m.workingDirectory with
  | .ok safeDir => return .ok safeDir
  | .error err => return .error (400, s!"\{\"error\":{jsonEscape err}}")

/-- Launch a local harness turn under `st.warmMgr?` (for `/btw/agent`, wakeup continuations, and `spawn_harness` turns). -/
private def launchLocalCoreMissionTurn
    (st : CoreAppState)
    (missionId harness cwd prompt model effort permMode : String)
    (sessionId? : Option String := none)
    (worktreeMode : String := "")
    (appendUserEvent : Bool := false) : IO (Except String String) := do
  let some mgr := st.warmMgr? | return .error "warm_harness_manager_unavailable"
  let effRawCwd := if cwd.trimAscii.toString.isEmpty then st.cfg.workingDir else cwd
  let safeCwd ← match ← confineWorkingDirectory st.cfg.workingDir effRawCwd with
    | .ok d => pure d
    | .error e => return .error s!"invalid_working_directory:{e}"
  let safeRoot ← match ← confineWorkingDirectory st.cfg.workingDir st.cfg.workingDir with
    | .ok d => pure d
    | .error e => return .error s!"invalid_working_directory:{e}"
  let binOverride := st.warmHarnessBinOverride?.getD ""
  let nowSec ← coreEpochSec
  let ts := formatEpochIso8601Utc nowSec
  if appendUserEvent then
    let userPl := renderCompact (.obj #[("content", .str prompt)])
    discard <| appendMissionEvent st.store missionId "user_message" userPl ts
  let prevSt? ← OrbBin.ClaudeControl.getRunState? mgr missionId
  let mut dbGen : UInt64 := 1
  if let .ok gRows ← execParamQuery st.store.missionsDb
      "SELECT COALESCE(run_generation,1) FROM missions WHERE id=?1;" #[missionId] then
    if gRows.size > 1 then dbGen := (Nat.max 1 (((gRows[1]?.bind (·[0]?)).bind String.toNat?).getD 1)).toUInt64
  let nextGen :=
    match prevSt? with
    | some s => max (dbGen + 1) (s.generation + 1)
    | none => if sessionId?.isSome then dbGen + 1 else dbGen
  discard <| execParamQuery st.store.missionsDb
    "UPDATE mission_continuations SET phase=3, error='stale_run_generation', updated_at=?3 WHERE mission_id=?1 AND phase=1 AND run_generation<CAST(?2 AS INTEGER);"
    #[missionId, s!"{nextGen}", ts]
  discard <| execParamQuery st.store.missionsDb
    "UPDATE missions SET status='active', run_generation=CAST(?2 AS INTEGER), state_revision=state_revision+1, updated_at=?3 WHERE id=?1;"
    #[missionId, s!"{nextGen}", ts]
  let model? := if model.trimAscii.toString.isEmpty then none else some model.trimAscii.toString
  let effort? := if effort.trimAscii.toString.isEmpty then none else some effort.trimAscii.toString
  let parsedPerm := OrbBin.ClaudeControl.parsePermissionMode permMode
  let wtArg := if worktreeMode.trimAscii.toString.isEmpty then "local" else worktreeMode.trimAscii.toString
  let cbs := buildCoreHarnessCallbacks st missionId
  let normHarness := if harness.trimAscii.toString.toLower == "claude" then "claudecode" else harness.trimAscii.toString
  match ← OrbBin.ClaudeControl.startHarnessTurn
      mgr missionId normHarness binOverride safeCwd prompt nextGen model? effort? sessionId? parsedPerm wtArg #[] cbs (some safeRoot) with
  | .ok runSt =>
    if runSt.cwd != safeCwd && !runSt.cwd.isEmpty then
      if let .ok safeWt ← confineWorkingDirectory st.cfg.workingDir runSt.cwd then
        discard <| execParamQuery st.store.missionsDb
          "UPDATE missions SET working_directory=?2 WHERE id=?1;" #[missionId, safeWt]
        return .ok safeWt
    return .ok safeCwd
  | .error err =>
    -- Nothing was started: the mission must not keep showing `active`.
    discard <| execParamQuery st.store.missionsDb
      ("UPDATE missions SET status='interrupted', terminal_reason='launch_failed', state_revision=state_revision+1, updated_at=?3 " ++
       "WHERE id=?1 AND status='active' AND run_generation=CAST(?2 AS INTEGER);")
      #[missionId, s!"{nextGen}", ts]
    return .error err

/-- Launch a live warm harness turn when `spawn_harness: true` is supplied by an authorized admin/legacy caller on a managed mission. -/
private def maybeSpawnWarmHarnessTurn
    (st : CoreAppState)
    (caller : CallerPrincipal)
    (placementKind : String)
    (missionId harness cwd prompt model effort permMode : String)
    (worktreeMode : String := "")
    (appendUserEvent : Bool := true) : IO (Option String) := do
  if !(caller.isLegacyUnscoped || caller.role == "admin") then return none
  if placementKind != "managed" && placementKind != "local" then return none
  let mut sid? : Option String := none
  if let .ok sRows ← execParamQuery st.store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[missionId] then
    if sRows.size > 1 then
      let s := (cell sRows[1]! 0).trimAscii.toString
      if !s.isEmpty then sid? := some s
  match ← launchLocalCoreMissionTurn st missionId harness cwd prompt model effort permMode sid? worktreeMode appendUserEvent with
  | .ok dir => return some dir
  | .error err =>
    if st.warmMgr?.isSome then
      let ts := formatEpochIso8601Utc (← coreEpochSec)
      let errPl := renderCompact (.obj #[("message", .str err)])
      discard <| appendMissionEvent st.store missionId "error" errPl ts
    return none

/-- Handle warm harness control, events, checkpoints, worktree, and permission routes. -/
private def dispatchMissionControlAndGitRoutes?
    (st : CoreAppState)
    (req : HttpRequest)
    (rawTarget cleanPath : String)
    (caller : CallerPrincipal)
    (reqOrigin? : Option String)
    (nowEpochSec : UInt64) : IO (Option (Except ByteArray CoreHttpResponse)) := do
  let mkJson (code : Nat) (bodyStr : String) : CoreHttpResponse :=
    jsonResponse code bodyStr #[] reqOrigin?
  let mkJsonHdr (code : Nat) (bodyStr : String) (hdrs : Array (String × String)) : CoreHttpResponse :=
    jsonResponse code bodyStr hdrs reqOrigin?

  if let some params := matchRoutePattern? "/api/control/missions/:id/events" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let qParams := parseQueryParams rawTarget
      let limNat := ((qParams.find? (fun p => p.1 == "limit")).bind (fun p => p.2.toNat?)).getD 200
      let sinceSeq? := ((qParams.find? (fun p => p.1 == "since_seq")).bind (fun p => p.2.toNat?)).map Nat.toUInt64
      let beforeSeq? := ((qParams.find? (fun p => p.1 == "before_seq")).bind (fun p => p.2.toNat?)).map Nat.toUInt64
      let maxPayload? := ((qParams.find? (fun p => p.1 == "max_payload")).bind (fun p => p.2.toNat?))
      let view? := ((qParams.find? (fun p => p.1 == "view")).map Prod.snd) |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let typesRaw := ((qParams.find? (fun p => p.1 == "types")).map Prod.snd).getD ""
      let typesArr :=
        if typesRaw.trimAscii.toString.isEmpty then #[]
        else (typesRaw.splitOn ",").toArray.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      match ← queryMissionEventsPage st.store mid sinceSeq? beforeSeq? limNat typesArr maxPayload? view? with
      | .error e => return some (.ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}"))
      | .ok pg =>
        let mut hdrs : Array (String × String) := #[
          ("X-Orb-Events-Protocol", "1"),
          ("X-Has-More", if pg.hasMore then "true" else "false"),
          ("X-Max-Sequence", s!"{pg.maxSeq}")
        ]
        if let some nc := pg.nextCursor then
          hdrs := hdrs.push ("X-Next-Cursor", s!"{nc}")
        if let some pm := pg.pageMaxSeq then
          hdrs := hdrs.push ("X-Page-Max-Sequence", s!"{pm}")
        return some (.ok (mkJsonHdr 200 pg.eventsJson hdrs))

  if let some params := matchRoutePattern? "/api/control/missions/:id/snapshot" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let qParams := parseQueryParams rawTarget
      let prof := ((qParams.find? (fun p => p.1 == "profile")).map Prod.snd |>.getD "presentation").trimAscii.toString
      match ← queryMissionEventsPage st.store mid none none 2 #[] (some 4096) (some "transcript") with
      | .error e => return some (.ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}"))
      | .ok pg =>
        let body := s!"\{\"profile\":{jsonEscape prof},\"revision\":{pg.maxSeq},\"activity\":\"\",\"events\":{pg.eventsJson}}"
        return some (.ok (mkJson 200 body))

  if let some params := matchRoutePattern? "/api/control/missions/:id/open" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      match ← missionDetailJson st.store mid callerOpt st.bootstrapAdminId with
      | .error e => return some (.ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}"))
      | .ok none => return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
      | .ok (some mJson) =>
        let qParams := parseQueryParams rawTarget
        let limNat := ((qParams.find? (fun p => p.1 == "limit")).bind (fun p => p.2.toNat?)).getD 200
        let sinceSeq? := ((qParams.find? (fun p => p.1 == "since_seq")).bind (fun p => p.2.toNat?)).map Nat.toUInt64
        let maxPayload := ((qParams.find? (fun p => p.1 == "max_payload")).bind (fun p => p.2.toNat?)).getD 4096
        let spineLim := ((qParams.find? (fun p => p.1 == "spine_limit")).bind (fun p => p.2.toNat?)).getD 80
        match ← queryMissionEventsPage st.store mid sinceSeq? none limNat #[] (some maxPayload) none with
        | .error e => return some (.ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}"))
        | .ok pg =>
          let queueJson ← match ← listRemoteQueueJson st.store "core" mid with
            | .ok qj => pure qj
            | .error _ => pure "[]"
          let (spineJson, spineHasMore, spineNextCursor?) ←
            if sinceSeq?.isNone && pg.hasMore && spineLim > 0 then
              match ← queryMissionEventsPage st.store mid none pg.nextCursor spineLim #[] (some maxPayload) (some "transcript") with
              | .ok spg => pure (spg.eventsJson, spg.hasMore, spg.nextCursor)
              | .error _ => pure ("[]", false, none)
            else
              pure ("[]", false, none)
          let ncJson := match pg.nextCursor with | some v => s!"{v}" | none => "null"
          let pmJson := match pg.pageMaxSeq with | some v => s!"{v}" | none => "null"
          let hmJson := if pg.hasMore then "true" else "false"
          let shmJson := if spineHasMore then "true" else "false"
          let sncJson := match spineNextCursor? with | some v => s!"{v}" | none => "null"
          let resetJson :=
            match sinceSeq? with
            | some s => if s > pg.maxSeq then "true" else "false"
            | none => "false"
          let bundle :=
            s!"\{\"protocol\":1,\"mission\":{mJson},\"events\":{pg.eventsJson},\"spine\":{spineJson}," ++
            s!"\"queue\":{queueJson},\"max_seq\":{pg.maxSeq},\"has_more\":{hmJson}," ++
            s!"\"spine_has_more\":{shmJson},\"spine_next_cursor\":{sncJson}," ++
            s!"\"next_cursor\":{ncJson},\"page_max_seq\":{pmJson},\"reset\":{resetJson}}"
          return some (.ok (mkJson 200 bundle))

  if let some params := matchRoutePattern? "/api/control/missions/:id/tool-calls/:callId" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let callId := (params.find? (fun p => p.1 == "callId")).map Prod.snd |>.getD ""
      match ← queryMissionToolCallEventsJson st.store mid callId with
      | .error e => return some (.ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}"))
      | .ok body => return some (.ok (mkJson 200 body))

  if let some params := matchRoutePattern? "/api/control/missions/:id/checkpoints" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let some m ← getMission? st.store mid
        | return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
      let safeDir ← match ← resolveConfinedCoreMissionGitDir st m with
        | .ok d => pure d
        | .error (cCode, cBody) => return some (.ok (mkJson cCode cBody))
      match ← OrbBin.GitWorkspace.listCheckpoints safeDir mid with
      | Except.ok cps =>
        let items := cps.map OrbBin.GitWorkspace.CheckpointMeta.toJVal
        return some (.ok (mkJson 200 (renderCompact (.obj #[("checkpoints", .arr items)]))))
      | Except.error err =>
        return some (.ok (mkJson 400 s!"\{\"error\":{jsonEscape err}}"))

  if let some params := matchRoutePattern? "/api/control/missions/:id/checkpoints/diff" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
      let some m ← getMission? st.store mid
        | return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
      let safeDir ← match ← resolveConfinedCoreMissionGitDir st m with
        | .ok d => pure d
        | .error (cCode, cBody) => return some (.ok (mkJson cCode cBody))
      let q := parseQueryParams rawTarget
      let fromRef := (((q.find? (fun p => p.1 == "from_ref")).map Prod.snd).filter (!·.isEmpty)).getD "HEAD"
      let toRef := (((q.find? (fun p => p.1 == "to_ref")).map Prod.snd).filter (!·.isEmpty)).getD "WORKTREE"
      let sinceEpoch? := ((q.find? (fun p => p.1 == "since_epoch")).bind (fun p => p.2.toNat?)).map Nat.toUInt64
      match ← OrbBin.GitWorkspace.diffCheckpoints safeDir fromRef toRef sinceEpoch? with
      | Except.ok rep =>
        return some (.ok (mkJson 200 (renderCompact rep.toJVal)))
      | Except.error err =>
        return some (.ok (mkJson 400 s!"\{\"error\":{jsonEscape err}}"))

  if let some params := matchRoutePattern? "/api/control/missions/:id/checkpoints/restore" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return some (.ok (mkJson cCode cBody))
      let some m ← getMission? st.store mid
        | return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
      let safeDir ← match ← resolveConfinedCoreMissionGitDir st m with
        | .ok d => pure d
        | .error (cCode, cBody) => return some (.ok (mkJson cCode cBody))
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return some (.ok (mkJson 400 "{\"error\":\"invalid_json\"}"))
      let ref := (jv.fieldStr? "ref").getD ""
      let turn? := jv.fieldNat? "turn"
      match ← OrbBin.GitWorkspace.restoreCheckpoint safeDir mid ref turn? with
      | Except.ok outJv =>
        return some (.ok (mkJson 200 (renderCompact outJv)))
      | Except.error err =>
        return some (.ok (mkJson 400 s!"\{\"error\":{jsonEscape err}}"))

  if let some params := matchRoutePattern? "/api/control/missions/:id/worktree" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if !isSafeMissionId mid then
      return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
    if let some (cCode, cBody) := (← authorizeMissionOp st caller mid (req.method != "GET")) then
      return some (.ok (mkJson cCode cBody))
    let some m ← getMission? st.store mid
      | return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
    let safeDir ← match ← resolveConfinedCoreMissionGitDir st m with
      | .ok d => pure d
      | .error (cCode, cBody) => return some (.ok (mkJson cCode cBody))
    let safeRoot ← match ← confineWorkingDirectory st.cfg.workingDir st.cfg.workingDir with
      | .ok r => pure r
      | .error err => return some (.ok (mkJson 400 s!"\{\"error\":{jsonEscape err}}"))
    let otherCwds ← match st.warmMgr? with
      | some mgr => OrbBin.ClaudeControl.activeRunCwdsExcept mgr mid
      | none => pure #[]
    if req.method == "GET" then
      let q := parseQueryParams rawTarget
      let preferWt := ((q.find? (fun p => p.1 == "prefer_worktree")).map Prod.snd) == some "true"
      let wtSt ← OrbBin.GitWorkspace.inspectWorktreeStatus safeDir mid otherCwds preferWt (some safeRoot)
      return some (.ok (mkJson 200 (renderCompact wtSt.toJVal)))
    else if req.method == "POST" then
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let baseBranch? := (jv.fieldStr? "base_branch").filter (!·.isEmpty)
      match ← OrbBin.GitWorkspace.createMissionWorktree safeDir mid baseBranch? (some safeRoot) with
      | Except.ok created =>
        let .ok safeWt ← confineWorkingDirectory st.cfg.workingDir created.worktreePath
          | return some (.ok (mkJson 400 "{\"error\":\"worktree_outside_workspace_root\"}"))
        discard <| execParamQuery st.store.missionsDb
          "UPDATE missions SET working_directory=?2,state_revision=state_revision+1,updated_at=?3 WHERE id=?1;"
          #[mid, safeWt, formatEpochIso8601Utc nowEpochSec]
        return some (.ok (mkJson 201 (renderCompact created.toJVal)))
      | Except.error err =>
        return some (.ok (mkJson 409 s!"\{\"error\":{jsonEscape err}}"))
    else if req.method == "DELETE" then
      let q := parseQueryParams rawTarget
      let force := ((q.find? (fun p => p.1 == "force")).map Prod.snd) == some "true"
      match ← OrbBin.GitWorkspace.removeMissionWorktree safeDir force with
      | Except.ok outJv => return some (.ok (mkJson 200 (renderCompact outJv)))
      | Except.error err => return some (.ok (mkJson 409 s!"\{\"error\":{jsonEscape err}}"))

  if let some params := matchRoutePattern? "/api/control/missions/:id/permission-mode" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return some (.ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}"))
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return some (.ok (mkJson cCode cBody))
      let some _ ← getMission? st.store mid
        | return some (.ok (mkJson 404 "{\"error\":\"mission_not_found\"}"))
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return some (.ok (mkJson 400 "{\"error\":\"invalid_json\"}"))
      let rawMode := (jv.fieldStr? "mode").getD "supervised"
      let parsedMode := OrbBin.ClaudeControl.parsePermissionMode rawMode
      let applied ← match st.warmMgr? with
        | some mgr => OrbBin.ClaudeControl.setSessionPermissionMode mgr mid parsedMode
        | none => pure false
      return some (.ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"mode\":{jsonEscape parsedMode.toUiWire},\"cli_mode\":{jsonEscape parsedMode.toCliWire},\"applied_live\":{if applied then "true" else "false"}}"))

  if req.method == "POST" && cleanPath == "/api/control/tool_result" then
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return some (.ok (mkJson 400 "{\"error\":\"invalid_json\"}"))
    let callId := (jv.fieldStr? "tool_call_id").getD ""
    let toolName := (jv.fieldStr? "name").getD "ui_native_request"
    let resultVal := (jv.field? "result").getD (.obj #[("action", .str "accept")])
    if callId.trimAscii.toString.isEmpty then
      return some (.ok (mkJson 400 "{\"error\":\"missing_tool_call_id\"}"))
    let explicitMid? := (jv.fieldStr? "mission_id").filter (!·.isEmpty)
    let mappedMid? ← match explicitMid? with
      | some m => pure (some m)
      | none =>
        match st.pendingControlCallsRef? with
        | some ref =>
          let xs ← ref.get
          pure ((xs.find? (fun p => p.1 == callId)).map Prod.snd)
        | none => pure none
    if let some mid := mappedMid? then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return some (.ok (mkJson cCode cBody))
    let mut delivered := false
    if let (some mgr, some mid) := (st.warmMgr?, mappedMid?) then
      delivered ← OrbBin.ClaudeControl.respondToControlRequest mgr mid callId resultVal
      if delivered then
        if let some ref := st.pendingControlCallsRef? then
          ref.modify fun xs => xs.filter (fun p => p.1 != callId)
        let ts := formatEpochIso8601Utc nowEpochSec
        let pl := renderCompact (.obj #[("tool_call_id", .str callId), ("tool_name", .str toolName), ("result", resultVal)])
        discard <| appendMissionEvent st.store mid "tool_result" pl ts
    return some (.ok (mkJson 200 s!"\{\"delivered\":{if delivered then "true" else "false"}}"))

  return none

set_option maxHeartbeats 1600000 in
private def dispatchCoreRequestRaw (st : CoreAppState) (req : HttpRequest) (nowEpochSec : UInt64) : IO (Except ByteArray CoreHttpResponse) := do
  let legacyManagedPrefix := "/api/managed/machines"
  let rawTarget := if req.path == legacyManagedPrefix || req.path.startsWith (legacyManagedPrefix ++ "/") || req.path.startsWith (legacyManagedPrefix ++ "?") then
      "/api/managed-machines" ++ (req.path.drop legacyManagedPrefix.length).toString
    else req.path
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
    let multiDb ← hasMultipleActiveUsers st.store
    -- `ORB_BUILD_SHA` is set by the deploy step, so a caller can tell which commit a service runs.
    let buildSha := ((← IO.getEnv "ORB_BUILD_SHA").getD "").trimAscii.toString
    let health := renderHealthJson st.cfg multiDb
    let body :=
      if buildSha.isEmpty || !health.endsWith "}" then health
      else (health.dropEnd 1).toString ++ s!",\"build\":{jsonEscape buildSha}}"
    return .ok (mkJsonHdr 200 body #[("Cache-Control", "private, max-age=5")])

  -- 2. Public Auth Login (`POST /api/auth/login`)
  if req.method == "POST" && cleanPath == "/api/auth/login" then
    let tape := JsonTape.indexJsonObject req.bodySlice
    let user? := JsonTape.lookupString? tape "username"
    let supplied := (JsonTape.lookupString? tape "password").getD ""
    let sec := effectiveJwtSecret st.cfg
    let exp := nowEpochSec + 86400
    let dbUser? ←
      match user?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) with
      | some uname => getUserByUsername? st.store uname
      | none => getBootstrapAdmin? st.store
    let settingsPwdOk ← do
      let isAdmName := match user? with | none => true | some s => s.trimAscii.isEmpty || s.trimAscii.toString == "admin"
      if isAdmName then verifySettingsPasswordHash st.store.rootDir supplied else pure false
    if let some u := dbUser? then
      if u.disabled then
        return .ok (mkJson 401 "{\"error\":\"account_disabled\"}")
      if (← verifyPasswordPbkdf2 supplied u.passwordHash) then
        let tok := mintSessionTokenV2 sec u.id u.role u.sessionEpoch exp
        let uJson := renderUserSummaryJson u
        return .ok (mkJson 200 s!"\{\"token\":{jsonEscape tok},\"exp\":{exp},\"expires_at\":{exp},\"user\":{uJson}}")
      -- If a specific non-admin DB account was named and PBKDF2 failed, reject unless static config matches
      if !verifyLoginCredentials st.cfg user? supplied && !settingsPwdOk then
        return .ok (mkJson 401 "{\"error\":\"invalid_credentials\"}")
      let tok := mintSessionTokenV2 sec u.id u.role u.sessionEpoch exp
      let uJson := renderUserSummaryJson u
      return .ok (mkJson 200 s!"\{\"token\":{jsonEscape tok},\"exp\":{exp},\"expires_at\":{exp},\"user\":{uJson}}")
    else if user?.any (fun s => !s.trimAscii.isEmpty) && (← hasMultipleActiveUsers st.store) && !verifyLoginCredentials st.cfg user? supplied then
      return .ok (mkJson 401 "{\"error\":\"invalid_credentials\"}")
    else if verifyLoginCredentials st.cfg user? supplied || settingsPwdOk then
      if let some adm ← getBootstrapAdmin? st.store then
        let tok := mintSessionTokenV2 sec adm.id adm.role adm.sessionEpoch exp
        let uJson := renderUserSummaryJson adm
        return .ok (mkJson 200 s!"\{\"token\":{jsonEscape tok},\"exp\":{exp},\"expires_at\":{exp},\"user\":{uJson}}")
      else
        let tok := mintSessionToken sec exp
        return .ok (mkJson 200 s!"\{\"token\":{jsonEscape tok},\"exp\":{exp},\"expires_at\":{exp}}")
    else
      return .ok (mkJson 401 "{\"error\":\"invalid_credentials\"}")

  -- 3. WebSocket Upgrade Endpoints (`/api/console/ws`, `/api/monitoring/ws`, `/api/desktop/stream`, `/api/workspaces/:id/shell`)
  if req.method == "GET" && isWsUpgradePath cleanPath rawTarget then
    if !authenticateConsoleWsUpgrade st.cfg req.headers nowEpochSec then
      return .ok (mkJson 401 "{\"error\":\"unauthorized_websocket\"}")
    let some wsCaller ← resolveCallerPrincipal? st req.headers nowEpochSec (allowWsSubproto := true)
      | return .ok (mkJson 401 "{\"error\":\"unauthorized_websocket\"}")
    if (cleanPath == "/api/console/ws" || cleanPath == "/api/desktop/stream" ||
        (matchRoutePattern? "/api/workspaces/:id/shell" rawTarget).isSome) &&
       !wsCaller.isLegacyUnscoped && wsCaller.role != "admin" then
      return .ok (mkJson 403 "{\"error\":\"admin_required\"}")
    let negProto? := negotiateWsSubprotocol? req.headers
    match buildWebSocketUpgradeResponse? req negProto? with
    | some raw101 => return .error raw101
    | none => return .ok (mkJson 400 "{\"error\":\"invalid_websocket_upgrade\"}")

  -- 4. Authenticated `/v1/*` LLM Proxy (`mission_proxy_token`, `SANDBOXED_PROXY_SECRET`, or Core Bearer Auth, `SM-21`)
  if cleanPath.startsWith "/v1/" then
    if !(← authenticateProxyRequest st req.headers nowEpochSec) then
      return .ok (mkJson 401 "{\"error\":\"unauthorized_proxy\"}")
    return .ok (← handleProxyRequest st req cleanPath reqOrigin? nowEpochSec)

  -- 5. Privilege Broker Verification & Audit Log (`POST /api/privilege-access/verify-and-log`)
  if req.method == "POST" && cleanPath == "/api/privilege-access/verify-and-log" then
    let some privCaller ← resolveCallerPrincipal? st req.headers nowEpochSec
      | return .ok (mkJson 401 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"unauthorized\"}")
    if !privCaller.isLegacyUnscoped && privCaller.role != "admin" then
      return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"admin_required\"}")
    let bodyStr := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
    let .ok jv := OrbBin.Json.parse bodyStr
      | return .ok (mkJson 400 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"invalid_json\"}")
    let missionId := (jv.fieldStr? "mission_id").getD ""
    let leaseTok := (jv.fieldStr? "lease_token").getD ""
    let targetHost := (jv.fieldStr? "target_host").getD ""
    let execHost := (jv.fieldStr? "executing_host").getD ""
    let cmdText := (jv.fieldStr? "command").getD ""
    let argv : Array String :=
      match jv.fieldArr? "argv" with
      | some xs => xs.filterMap JVal.asStr?
      | none =>
        let toks := (cmdText.splitOn " ").filter (fun s => !s.isEmpty)
        toks.toArray
    let isPostExecLog := (jv.field? "exit_code").isSome
    if missionId.isEmpty || leaseTok.isEmpty || targetHost.isEmpty then
      return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"missing_lease_fields\"}")
    let some lease ← lookupPrivilegeLease? st.store leaseTok
      | do
        discard <| appendPrivilegeAuditLog st.store "" missionId targetHost execHost cmdText false s!"{nowEpochSec}"
        return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"unknown_lease\"}")
    let some sRank := scopeRankOf? lease.scope
      | do
        discard <| appendPrivilegeAuditLog st.store lease.grantId missionId targetHost execHost cmdText false s!"{nowEpochSec}"
        return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"unknown_privilege_scope\"}")
    let allowedUnits : Array String :=
      match OrbBin.Json.parse lease.allowedUnitsJson with
      | .ok (.arr us) => us.filterMap JVal.asStr?
      | _ => #[]
    let normLeaseHost := normalizeTargetHost lease.targetHost
    let normReqTarget := normalizeTargetHost targetHost
    let normExecHost  := normalizeTargetHost execHost
    let targetMatches : Bool :=
      normLeaseHost == "all" ||
      normLeaseHost == normReqTarget ||
      (normReqTarget == "self" && (normExecHost.isEmpty || normExecHost == "self" || normLeaseHost == normExecHost))
    let execMatches : Bool :=
      normReqTarget == "self" ||
      normLeaseHost == "all" ||
      normExecHost.isEmpty ||
      normExecHost == normReqTarget ||
      normExecHost == normLeaseHost
    let cmdScopeOk ←
      if isPostExecLog then
        pure true
      else if cmdText == "[update_harness]" then
        pure (sRank ≥ 1)
      else if argv.isEmpty then
        pure false
      else do
        match ← OrbBin.PrivdShared.checkScopeRestrictions lease.scope allowedUnits argv (jv.fieldStr? "cwd") #[] lease.requireForceCmd with
        | .ok _ => pure true
        | .error _ => pure false
    let liveBunker ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
    let bunkerWord := bunkerStep liveBunker 0 0 0 0
    let bunkerState : UInt8 := (bunkerWord &&& 0xFF).toUInt8
    let sameOwner : UInt8 := if lease.missionId == missionId && targetMatches && execMatches then 1 else 0
    let privWord := privilegeStep
      sameOwner 1
      (if lease.biometricSigned then 1 else 0)
      sRank sRank bunkerState
      (if lease.revoked then 1 else 0)
      nowEpochSec lease.expiresAtEpoch (lease.expiresAtEpoch + 3600)
    let rawTgtHash : UInt32 := (hash64Fnv1a normLeaseHost &&& 0xFFFFFFFF).toUInt32
    let tgtHash : UInt32 := if rawTgtHash == 0 then 1 else rawTgtHash
    let execHash : UInt32 :=
      if execMatches then tgtHash
      else
        let h := (hash64Fnv1a (normExecHost ++ ":mismatch") &&& 0xFFFFFFFF).toUInt32
        if h == 0 || h == tgtHash then tgtHash ^^^ 1 else h
    let cmdDigest := hash64Fnv1a (cmdText ++ "\x00" ++ String.intercalate "\x00" argv.toList)
    let principalKind : UInt8 := sRank + 1
    let liveLeaseEp : UInt64 := if lease.leaseEpoch != 0 then lease.leaseEpoch else lease.expiresAtEpoch
    let toctouWord := authToctouExecuteStep principalKind bunkerState
      tgtHash execHash
      liveLeaseEp (if lease.revoked then 0 else liveLeaseEp) nowEpochSec lease.expiresAtEpoch
      cmdDigest cmdDigest
    let allowExec := cmdScopeOk && (privWord &&& 1) == 1 && toctouWord == 257
    if let .error e ← appendPrivilegeAuditLog st.store lease.grantId missionId targetHost execHost cmdText allowExec s!"{nowEpochSec}" then
      return .ok (mkJson 500 s!"\{\"allow_exec\":false,\"allowed\":false,\"bunker_state\":{bunkerState.toNat},\"expires_at\":{lease.expiresAtEpoch},\"lease_epoch\":{if lease.revoked then 0 else liveLeaseEp},\"error\":{jsonEscape e}}")
    if !allowExec then
      let denyReason := if bunkerState != 0 then "bunker_active" else "lease_denied"
      return .ok (mkJson 403 s!"\{\"allow_exec\":false,\"allowed\":false,\"bunker_state\":{bunkerState.toNat},\"expires_at\":{lease.expiresAtEpoch},\"lease_epoch\":{if lease.revoked then 0 else liveLeaseEp},\"error\":{jsonEscape denyReason}}")
    let rfStr := if lease.requireForceCmd then "true" else "false"
    let unitsRaw := if lease.allowedUnitsJson.startsWith "[" then lease.allowedUnitsJson else "[]"
    return .ok (mkJson 200 s!"\{\"allow_exec\":true,\"allowed\":true,\"grant_id\":{jsonEscape lease.grantId},\"scope\":{jsonEscape lease.scope},\"allowed_units\":{unitsRaw},\"require_force_cmd\":{rfStr},\"bunker_state\":{bunkerState.toNat},\"expires_at\":{lease.expiresAtEpoch},\"lease_epoch\":{liveLeaseEp}}")

  -- 5b. Unified Control-Plane MCP Gateway (`/api/mcp/session`, `/api/mcp/external-sessions`, `/api/mcp/renew`, `/api/mcp/capabilities`, `/api/mcp/call`)
  if cleanPath.startsWith "/api/mcp/" then
    let bearerTok? := extractBearerToken? req.headers nowEpochSec
    let rawScopedClaims? := bearerTok?.bind (verifyScopedMcpToken? st.cfg.jwtSecret · nowEpochSec)
    let scopedClaims? ← match rawScopedClaims? with
      | none => pure none
      | some c =>
        match ← execParamQuery st.store.projectsDb
            "SELECT revoked, hard_expires_at, COALESCE(project_scope,''), COALESCE(project_scoped,0) FROM mcp_sessions_v1 WHERE id=?1;" #[c.sessionId] with
        | .ok rs =>
          if rs.size ≤ 1 then
            pure (if c.isExternal then none else some c)
          else
            let rev := ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
            let hExp := (((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0).toUInt64
            let dbProj := (rs[1]?.bind (·[2]?)).getD ""
            let dbProjScoped := (((rs[1]?.bind (·[3]?)).bind String.toNat?).getD 0) != 0
            if rev != 0 || (hExp > 0 && nowEpochSec ≥ hExp) then pure none
            else
              let liveProj := if dbProjScoped then dbProj else c.project
              pure (some { c with project := liveProj, hardExpiresAt := if hExp > 0 then hExp else c.hardExpiresAt })
        | .error _ => pure none
    let mcpCaller? ← resolveCallerPrincipal? st req.headers nowEpochSec
    let coreAuthed := mcpCaller?.isSome

    if req.method == "POST" && cleanPath == "/api/mcp/external-sessions" then
      let some mcpCaller := mcpCaller?
        | return .ok (mkJson 401 "{\"error\":\"unauthorized_mcp_session\"}")
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let rawRole := (jv.fieldStr? "role").getD "executor"
      let role := normalizeMcpRole rawRole
      if role == "operator" then
        return .ok (mkJson 403 "{\"error\":\"External MCP sessions cannot hold the operator role\"}")
      let bunkerSt ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
      if bunkerSt ≥ 2 then
        return .ok (mkJson 403 "{\"error\":\"Bunker HardLockdown is active; external MCP sessions cannot be minted\"}")
      let ttlDays? := jv.fieldNat? "ttl_days"
      let hardHours? := jv.fieldNat? "hard_ttl_hours"
      if ttlDays?.isSome && hardHours?.isSome then
        return .ok (mkJson 400 "{\"error\":\"Specify either ttl_days or hard_ttl_hours, not both\"}")
      let hours := match hardHours?, ttlDays? with
        | some h, none => h
        | none, some d => d * 24
        | _, _         => 7 * 24
      if hours == 0 || hours > 30 * 24 then
        return .ok (mkJson 400 "{\"error\":\"External session TTL must be between 1 hour and 30 days\"}")
      let proj := ((jv.fieldStr? "project").getD "").trimAscii.toString
      let clientLabel := ((jv.fieldStr? "client_label").getD "local_mcp").trimAscii.toString
      let hostHint := ((jv.fieldStr? "host_hint").getD "").trimAscii.toString
      let sid ← nextMcpSessionUuid st
      let hardExp := nowEpochSec + (hours * 3600).toUInt64
      let rollingExp := min (nowEpochSec + 3600) hardExp
      let claims : McpSessionClaims := {
        sessionId := sid, missionId := "", role := role,
        project := proj, isExternal := true, expiresAt := rollingExp, hardExpiresAt := hardExp
      }
      let scopedTok := mintScopedMcpToken st.cfg.jwtSecret claims
      let insRes ← execParamQuery st.store.projectsDb
        ("INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind,client_label,host_hint,project_scope,hard_expires_at) " ++
         "VALUES(?1,?2,'',?3,0,'external_session',?4,?5,?6,?7);")
        #[sid, mcpCaller.userId, toString rollingExp, clientLabel, hostHint, proj, toString hardExp]
      if let .error _ := insRes then
        return .ok (mkJson 503 "{\"error\":\"session_store_unavailable\"}")
      let projJson : JVal := if proj.isEmpty then .null else .str proj
      let outJv := JVal.obj #[
        ("token", .str scopedTok),
        ("expires_at", JVal.uint64 rollingExp),
        ("hard_expires_at", JVal.uint64 hardExp),
        ("session_id", .str sid),
        ("role", .str role),
        ("project", projJson),
        ("contract_version", .str OrbBin.McpCatalog.contractVersion)
      ]
      return .ok (mkJson 200 (renderCompact outJv))

    if req.method == "GET" && cleanPath == "/api/mcp/external-sessions" then
      let some mcpCaller := mcpCaller?
        | return .ok (mkJson 401 "{\"error\":\"unauthorized\"}")
      match ← execParamQuery st.store.projectsDb
          ("SELECT id, expires_at, revoked, client_label, host_hint, project_scope, hard_expires_at " ++
           "FROM mcp_sessions_v1 WHERE owner=?1 AND subject_kind='external_session' " ++
           "ORDER BY hard_expires_at DESC LIMIT 200;")
          #[mcpCaller.userId] with
      | .error _ => return .ok (mkJson 503 "{\"error\":\"session_store_unavailable\"}")
      | .ok rs =>
        let mut items : Array JVal := #[]
        for i in [1:rs.size] do
          let r := rs[i]!
          let sid := (r[0]?).getD ""
          let exp := (((r[1]?).bind String.toNat?).getD 0).toUInt64
          let rev := (((r[2]?).bind String.toNat?).getD 0) != 0
          let lbl := (r[3]?).getD ""
          let hh := (r[4]?).getD ""
          let pj := (r[5]?).getD ""
          let hExp := (((r[6]?).bind String.toNat?).getD 0).toUInt64
          let active := !rev && (hExp == 0 || nowEpochSec < hExp)
          items := items.push (.obj #[
            ("session_id", .str sid),
            ("expires_at", JVal.uint64 exp),
            ("hard_expires_at", if hExp > 0 then JVal.uint64 hExp else .null),
            ("revoked", .bool rev),
            ("active", .bool active),
            ("client_label", if lbl.isEmpty then .null else .str lbl),
            ("host_hint", if hh.isEmpty then .null else .str hh),
            ("project", if pj.isEmpty then .null else .str pj)
          ])
        return .ok (mkJson 200 (renderCompact (.obj #[("sessions", .arr items)])))

    if req.method == "DELETE" then
      if let some params := matchRoutePattern? "/api/mcp/external-sessions/:id" cleanPath then
        let some mcpCaller := mcpCaller?
          | return .ok (mkJson 401 "{\"error\":\"unauthorized\"}")
        let sid := ((params.find? (fun (k, _) => k == "id")).map Prod.snd).getD ""
        match ← execParamQuery st.store.projectsDb
            "SELECT 1 FROM mcp_sessions_v1 WHERE id=?1 AND owner=?2 AND subject_kind='external_session';"
            #[sid, mcpCaller.userId] with
        | .error _ => return .ok (mkJson 503 "{\"error\":\"session_store_unavailable\"}")
        | .ok rs =>
          if rs.size ≤ 1 then
            return .ok (mkJson 404 "{\"error\":\"not_found\"}")
          let _ ← execParamQuery st.store.projectsDb
            "UPDATE mcp_sessions_v1 SET revoked=1 WHERE id=?1 AND owner=?2 AND subject_kind='external_session';"
            #[sid, mcpCaller.userId]
          return .ok (mkJson 200 (renderCompact (.obj #[("revoked", .bool true), ("session_id", .str sid)])))

    if req.method == "POST" && cleanPath == "/api/mcp/session" then
      let some mcpCaller := mcpCaller?
        | return .ok (mkJson 401 "{\"error\":\"unauthorized_mcp_session\"}")
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let mid := (jv.fieldStr? "mission_id").getD ""
      if mid.trimAscii.toString.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_mission_id\"}")
      if let some (cCode, cBody) ← authorizeMissionOp st mcpCaller mid false then
        return .ok (mkJson cCode cBody)
      let role := normalizeMcpRole ((jv.fieldStr? "role").getD "executor")
      let proj := (jv.fieldStr? "project").getD ""
      let sid ← nextMcpSessionUuid st
      let exp := nowEpochSec + 3600
      let projScopedFlag := if proj.trimAscii.toString.isEmpty then "0" else "1"
      discard <| execParamQuery st.store.projectsDb
        ("INSERT OR REPLACE INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind,client_label,host_hint,project_scope,project_scoped,hard_expires_at) " ++
         "VALUES(?1,?2,?3,?4,0,'mission','', '',?5,?6,?4);")
        #[sid, mcpCaller.userId, mid, toString exp, proj.trimAscii.toString, projScopedFlag]
      let claims : McpSessionClaims := {
        sessionId := sid, missionId := mid, role := role,
        project := proj, isExternal := false, expiresAt := exp
      }
      let scopedTok := mintScopedMcpToken st.cfg.jwtSecret claims
      return .ok (mkJson 200 s!"\{\"token\":{jsonEscape scopedTok},\"session_id\":{jsonEscape sid},\"expires_at\":{exp}}")

    if req.method == "POST" && cleanPath == "/api/mcp/renew" then
      let renewClaims? := bearerTok?.bind (verifyScopedMcpTokenForRenew? st.cfg.jwtSecret · nowEpochSec)
      let some prev := renewClaims?
        | return .ok (mkJson 401 "{\"error\":\"invalid_or_expired_scoped_token\"}")
      if prev.isExternal then
        let bunkerSt ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
        if bunkerSt ≥ 2 then
          return .ok (mkJson 403 "{\"error\":\"Bunker HardLockdown is active; external MCP sessions cannot renew\"}")
      let mut effHardExp := prev.hardExpiresAt
      match ← execParamQuery st.store.projectsDb
          "SELECT revoked, hard_expires_at FROM mcp_sessions_v1 WHERE id=?1;" #[prev.sessionId] with
      | .error _ => return .ok (mkJson 503 "{\"error\":\"session_store_unavailable\"}")
      | .ok rs =>
        if rs.size ≤ 1 then
          if prev.isExternal then
            return .ok (mkJson 401 "{\"error\":\"mcp_session_revoked\"}")
        else
          let rev := ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0
          let dbHard := (((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0).toUInt64
          if dbHard > 0 then effHardExp := dbHard
          if rev != 0 || (effHardExp > 0 && nowEpochSec ≥ effHardExp) then
            return .ok (mkJson 401 "{\"error\":\"mcp_session_revoked_or_expired\"}")
      let rawNextExp := nowEpochSec + 3600
      let nextExp := if effHardExp > 0 then min rawNextExp effHardExp else rawNextExp
      let _ ← execParamQuery st.store.projectsDb
        "UPDATE mcp_sessions_v1 SET expires_at=?2 WHERE id=?1 AND revoked=0;"
        #[prev.sessionId, toString nextExp]
      let renewed : McpSessionClaims := { prev with expiresAt := nextExp, hardExpiresAt := effHardExp }
      let nextTok := mintScopedMcpToken st.cfg.jwtSecret renewed
      return .ok (mkJson 200 s!"\{\"token\":{jsonEscape nextTok},\"session_id\":{jsonEscape renewed.sessionId},\"expires_at\":{nextExp}}")

    let effClaims? : Option McpSessionClaims :=
      match scopedClaims? with
      | some c => some c
      | none =>
        if coreAuthed then
          some {
            sessionId := "00000000-0000-4000-8000-000000000000"
            missionId := ""
            role := "operator"
            project := ""
            isExternal := false
            expiresAt := nowEpochSec + 3600
          }
        else none

    let some activeClaims := effClaims?
      | return .ok (mkJson 401 "{\"error\":\"unauthorized_mcp\"}")

    if req.method == "GET" && cleanPath == "/api/mcp/capabilities" then
      return .ok (mkJson 200 (buildMcpCapabilitiesJson activeClaims))

    if req.method == "POST" && cleanPath == "/api/mcp/call" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"ok\":false,\"error\":{\"code\":\"invalid_json\",\"message\":\"Malformed JSON body\",\"accepted\":\"no\",\"retryable\":false}}")
      let toolName := (jv.fieldStr? "name").getD ""
      let args := (jv.field? "arguments").getD (.obj #[])
      if isMemoryToolName toolName then
        let mut onManagedNode := false
        let mut hasProjSkill := !activeClaims.isExternal && !activeClaims.project.isEmpty
        if !activeClaims.missionId.isEmpty then
          if let .ok mRs ← execParamQuery st.store.missionsDb
              "SELECT placement_kind, project, tags FROM missions WHERE id=?1;" #[activeClaims.missionId] then
            if mRs.size > 1 then
              let pk := (mRs[1]?.bind (·[0]?)).getD ""
              let mProj := (mRs[1]?.bind (·[1]?)).getD ""
              let mTags := parseStringJsonArray ((mRs[1]?.bind (·[2]?)).getD "[]")
              if pk == "managed_vm" || pk.startsWith "managed-" then
                onManagedNode := true
              if !activeClaims.isExternal && (!mProj.isEmpty || mTags.contains "skill:spark-memory") then
                hasProjSkill := true
          if !onManagedNode then
            if let some mst := st.managedStore? then
              if let .ok vmRs ← execParamQuery mst.db
                  ("SELECT 1 FROM managed_machines WHERE owner_mission=?1 AND status<>'destroyed' " ++
                   "UNION ALL SELECT 1 FROM managed_vm_claims WHERE owner_mission=?1 AND phase_code=1 LIMIT 1;")
                  #[activeClaims.missionId] then
                if vmRs.size > 1 then
                  onManagedNode := true
        let bunkerSt ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
        let memCache ← match st.memTokenCache? with | some c => pure c | none => newMemoryTokenCache
        let ctx : MemoryCallerContext := {
          callerRole := roleCodeFor activeClaims.role
          isExternalSession := activeClaims.isExternal
          onManagedNode := onManagedNode
          bunkerState := bunkerSt
          hasProjectMemorySkill := hasProjSkill
          hasSecretAccess := false
        }
        match ← executeMemoryMcpTool memCache ctx toolName args nowEpochSec with
        | .ok resVal =>
          return .ok (mkJson 200 (renderCompact (.obj #[("ok", .bool true), ("result", resVal)])))
        | .error errMsg =>
          let errJson := renderCompact (.obj #[
            ("ok", .bool false),
            ("error", .obj #[
              ("code", .str "memory_tool_denied"),
              ("message", .str errMsg),
              ("accepted", .str "no"),
              ("retryable", .bool false)
            ])
          ])
          return .ok (mkJson 200 errJson)
      else
        let outJson ← dispatchMcpToolCall
          st.store st.managedStore? st.relayHub? st.broadcastHub? (← st.managedRef.get)
          st.cfg.workingDir activeClaims toolName args nowEpochSec st.remoteSup? st.managedProvisioningOverride?
          (if scopedClaims?.isNone then (mcpCaller?.map (·.userId)).getD "" else "")
          (scopedClaims?.isNone && (mcpCaller?.map (fun c => !c.disabled && (c.isLegacyUnscoped || c.role == "admin"))).getD false)
        return .ok (mkJson 200 outJson)

  -- 5c. Managed Node Dial-Out Enrollment & Leased Relay
  if req.method == "POST" && cleanPath == "/api/managed-machines/enroll" then
    let some mst := st.managedStore?
      | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    let mid := (jv.fieldStr? "machine_id").getD ""
    let tok := (jv.fieldStr? "enroll_token").getD ""
    let boot? := jv.fieldUInt64? "node_boot_epoch"
    match ← enrollManagedNode mst mid tok boot? with
    | .error "stale_boot_epoch" => return .ok (mkJson 410 "{\"error\":\"stale_boot_epoch\"}")
    | .error _ => return .ok (mkJson 401 "{\"error\":\"enrollment_rejected\"}")
    | .ok (nodeId, nodeToken) =>
      return .ok (mkJson 200 s!"\{\"node_id\":{jsonEscape nodeId},\"node_token\":{jsonEscape nodeToken}}")

  if req.method == "GET" && cleanPath == "/api/managed-machines/relay/poll" then
    let some mst := st.managedStore?
      | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
    let mid := (lookupHeaderCI req.headers "x-orb-machine-id").getD ""
    let boot? := ((lookupHeaderCI req.headers "x-orb-boot-epoch").bind String.toNat?).map Nat.toUInt64
    let nodeTok := (extractBearerToken? req.headers nowEpochSec).getD ""
    match ← authenticateAndRecordManagedPoll mst mid nodeTok boot? nowEpochSec with
    | .error "stale_boot_epoch" => return .ok (mkJson 410 "{\"error\":\"stale_boot_epoch\"}")
    | .error _ => return .ok (mkJson 401 "{\"error\":\"node_unauthorized\"}")
    | .ok vmBoot =>
      if let some rHub := st.relayHub? then
        recordMachinePollSeen rHub mid nowEpochSec
        let httpReqs ← drainRelayHttpReqs rHub mid
        if !httpReqs.isEmpty then
          return .ok (mkJson 200 (renderRelayHttpReqsJson httpReqs))
      match ← pollRelayLease mst mid vmBoot nowEpochSec (nowEpochSec + 60) with
      | .error _ => return .ok (mkJson 410 "{\"error\":\"stale_boot_epoch\"}")
      | .ok (some cmd) => return .ok (mkJson 200 (renderRelayPollJson cmd))
      | .ok none =>
        if let some rHub := st.relayHub? then
          if rHub.longPollMs > 0 then
            let mut waitedMs : Nat := 0
            while waitedMs < rHub.longPollMs do
              IO.sleep 100
              waitedMs := waitedMs + 100
              let liveSec ← coreEpochSec
              recordMachinePollSeen rHub mid liveSec
              let httpReqs ← drainRelayHttpReqs rHub mid
              if !httpReqs.isEmpty then
                return .ok (mkJson 200 (renderRelayHttpReqsJson httpReqs))
        return .ok (mkJson 200 "[]")

  if req.method == "POST" && cleanPath == "/api/managed-machines/relay/respond" then
    let some mst := st.managedStore?
      | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
    let mid := (lookupHeaderCI req.headers "x-orb-machine-id").getD ""
    let boot? := ((lookupHeaderCI req.headers "x-orb-boot-epoch").bind String.toNat?).map Nat.toUInt64
    let nodeTok := (extractBearerToken? req.headers nowEpochSec).getD ""
    match ← authenticateNodeToken mst mid nodeTok boot? with
    | .error "stale_boot_epoch" => return .ok (mkJson 410 "{\"error\":\"stale_boot_epoch\"}")
    | .error _ => return .ok (mkJson 401 "{\"error\":\"node_unauthorized\"}")
    | .ok vmBoot =>
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      if let some rHub := st.relayHub? then
        recordMachinePollSeen rHub mid nowEpochSec
      if (jv.fieldUInt64? "lease_id").isNone then
        if let some rHub := st.relayHub? then
          if let some httpResp := parseRelayHttpRespJson? jv then
            deliverRelayHttpResp rHub httpResp
            return .ok (mkJson 200 "{\"ok\":true}")
      let cmdId := (jv.fieldStr? "id").getD ""
      let leaseId := (jv.fieldUInt64? "lease_id").getD 0
      match ← stepRelayCommand mst cmdId {
        opCode := Orb.ManagedNode.RelayOp.encode .ack
        presentedLeaseId := leaseId
        presentedBootEpoch := vmBoot
        nowEpoch := nowEpochSec
      } with
      | .error "stale_boot_epoch" => return .ok (mkJson 410 "{\"error\":\"stale_boot_epoch\"}")
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 200 "{\"ok\":true}")

  if req.method == "GET" && cleanPath.startsWith "/api/managed-machines/bootstrap-binary/" then
    if let some mst := st.managedStore? then
      if let some (bStatus, bCtype, bBody) ← dispatchRemoteFleetAndRelayRoutes?
          st.store mst st.relayHub? (← st.managedRef.get) req.method cleanPath rawTarget
          req.headers req.bodySlice.toByteArray "" true true nowEpochSec (formatEpochIso8601Utc nowEpochSec) st.managedProvisioningOverride? then
        return .ok { status := bStatus, contentType := bCtype, corsOrigin? := reqOrigin?, body := bBody }

  -- 6. Protected Routes (`require_auth` + `resolveCallerPrincipal?`)
  let some caller ← resolveCallerPrincipal? st req.headers nowEpochSec
    | return .ok (mkJson 401 "{\"error\":\"unauthorized\"}")
  let utcDay := currentUtcDay nowEpochSec

  -- Explicit operator-triggered vault-to-Core sealing. Reauthenticate with dev
  -- bypass disabled: an open dev-mode API must not grant vault authority.
  let sealSegments := cleanPath.splitOn "/" |>.filter (!·.isEmpty)
  if req.method == "POST" && sealSegments.length == 5 &&
      sealSegments.take 3 == ["api", "managed-machines", "providers"] &&
      sealSegments[4]? == some "seal" then
    let some rawToken := extractBearerToken? req.headers nowEpochSec
      | return .ok (mkJson 401 "{\"error\":\"operator_authentication_required\"}")
    -- Dev login can mint an admin token without checking a password, and the
    -- legacy raw-password fallback maps any configured password to bootstrap
    -- admin. Neither is authority to access the provider vault.
    if st.cfg.devMode || !(validateRuntimeSecurity st.cfg).isOk then
      return .ok (mkJson 403 "{\"error\":\"managed_sealing_requires_secure_auth\"}")
    if !rawToken.startsWith "orb-jwt-v2:" then
      return .ok (mkJson 401 "{\"error\":\"operator_session_required\"}")
    let some operator ← resolveCallerPrincipal? st req.headers nowEpochSec
      | return .ok (mkJson 401 "{\"error\":\"operator_authentication_required\"}")
    let missionCredential := rawToken.startsWith "mcp1." || rawToken.startsWith "orb-mpt-v1_"
    let provider := sealSegments[3]!
    -- V2 sessions resolve a live user's stored role and epoch, never a generic
    -- password, legacy JWT, guest node token or caller-supplied authority flag.
    let result ← ManagedProviderSealing.sealReserved st.store.rootDir provider
      (operator.role == "admin") missionCredential false
      (resolveReservedComputeSecret st.cfg.workingDir st.store.rootDir)
    match result with
    | .ok () =>
      return .ok (mkJson 200 (renderCompact (.obj #[("provider", .str provider), ("sealed", .bool true)])))
    | .error error =>
      let (status, code) := if error == "operator_required" then (403, error)
        else if error == "managed_provider_secret_unsupported" then (400, error)
        else if error == "managed_provider_secret_lookup_failed" then (503, error)
        else if error == "managed_secret_seal_busy" then (409, error)
        else (500, "managed_provider_secret_seal_failed")
      return .ok (mkJson status (renderCompact (.obj #[("error", .str code)])))

  -- 6a. Self-Account, Auth Status & User Directory (`opClass = 0`)
  if req.method == "GET" && (cleanPath == "/api/auth/me" || cleanPath == "/api/auth/status") then
    let multiDb ← hasMultipleActiveUsers st.store
    let authMode :=
      if st.cfg.devMode then "disabled"
      else if multiDb || !(parseConfiguredUsers st.cfg.usersJson).isEmpty then "multi_user"
      else "single_tenant"
    let pwdSrc := if st.cfg.devMode then "none" else if !st.cfg.usersJson.isEmpty || multiDb then "users" else "env"
    let isAdmin := caller.role == "admin"
    let (infSpent, cmpSpent) ←
      if caller.userId.isEmpty then pure (0, 0)
      else getUserSpentTodayCents st.store caller.userId utcDay
    let totalSpent := infSpent + cmpSpent
    let unixJson := match caller.unixUsername? with | some ux => jsonEscape ux | none => "null"
    let capJson := match caller.dailySpendCapCents? with | some c => s!"{c}" | none => "null"
    let admStr := if isAdmin then "true" else "false"
    let devStr := if st.cfg.devMode then "true" else "false"
    let authReqStr := if !st.cfg.devMode then "true" else "false"
    let userObj :=
      s!"\{\"id\":{jsonEscape (if caller.userId.isEmpty then "admin" else caller.userId)}," ++
      s!"\"username\":{jsonEscape caller.username},\"role\":{jsonEscape caller.role}," ++
      s!"\"unix_username\":{unixJson},\"daily_spend_cap_cents\":{capJson},\"spent_today_cents\":{totalSpent}}"
    let capsObj :=
      s!"\{\"can_manage_users\":{admStr},\"can_use_core_target\":{admStr},\"can_manage_global_providers\":{admStr}}"
    return .ok (mkJson 200 (
      s!"\{\"auth_mode\":{jsonEscape authMode},\"password_source\":{jsonEscape pwdSrc}," ++
      s!"\"dev_mode\":{devStr},\"auth_required\":{authReqStr},\"authenticated\":true," ++
      s!"\"user\":{userObj},\"capabilities\":{capsObj}}"))

  if req.method == "POST" && cleanPath == "/api/auth/change-password" then
    if caller.userId.isEmpty then
      return .ok (mkJson 400 "{\"error\":\"account_not_persisted\"}")
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    let curPwd := (jv.fieldStr? "current_password").getD ""
    let nextPwd := (jv.fieldStr? "new_password").orElse (fun _ => jv.fieldStr? "password") |>.getD ""
    let some uRec ← getUserById? st.store caller.userId
      | return .ok (mkJson 404 "{\"error\":\"user_not_found\"}")
    if !(← verifyPasswordPbkdf2 curPwd uRec.passwordHash) then
      return .ok (mkJson 401 "{\"error\":\"invalid_current_password\"}")
    match ← resetUserPasswordRecord st.store caller.userId nextPwd s!"{nowEpochSec}" with
    | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
    | .ok updated =>
      let exp := nowEpochSec + 86400
      let tok := mintSessionTokenV2 (effectiveJwtSecret st.cfg) updated.id updated.role updated.sessionEpoch exp
      return .ok (mkJson 200 s!"\{\"ok\":true,\"token\":{jsonEscape tok},\"exp\":{exp},\"expires_at\":{exp}}")

  if req.method == "GET" && cleanPath == "/api/users/directory" then
    match ← listUserDirectoryJson st.store caller.userId with
    | .ok body => return .ok (mkJson 200 body)
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- 6b. Admin User Management (`/api/admin/users`, `/api/admin/users/:id`, `/api/admin/users/:id/reset-password`, `opClass = 1`)
  if cleanPath == "/api/admin/users" || cleanPath.startsWith "/api/admin/users/" then
    if let some (cCode, cBody) := requireAdminPrincipal caller then
      return .ok (mkJson cCode cBody)
    if req.method == "GET" && cleanPath == "/api/admin/users" then
      match ← listUsersAdminJson st.store utcDay with
      | .ok body => return .ok (mkJson 200 body)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" && cleanPath == "/api/admin/users" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let uname := (jv.fieldStr? "username").getD ""
      let pwd := (jv.fieldStr? "password").getD ""
      let role := ((jv.fieldStr? "role").getD "member").trimAscii.toString.toLower
      let unixOpt := jv.fieldStr? "unix_username"
      let capRes : Except String (Option UInt64) :=
        parseOptionalBoundedU64 jv "daily_spend_cap_cents" 0 1000000000
      let .ok capOpt := capRes
        | return .ok (mkJson 400 "{\"error\":\"invalid_daily_spend_cap_cents\"}")
      match ← createUserRecord st.store uname pwd role unixOpt capOpt s!"{nowEpochSec}" with
      | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
      | .ok created =>
        let unixJson := match created.unixUsername? with | some ux => jsonEscape ux | none => "null"
        let capJson := match created.dailySpendCapCents? with | some c => s!"{c}" | none => "null"
        return .ok (mkJson 201 (
          s!"\{\"id\":{jsonEscape created.id},\"username\":{jsonEscape created.username},\"role\":{jsonEscape created.role}," ++
          s!"\"unix_username\":{unixJson},\"disabled\":false,\"daily_spend_cap_cents\":{capJson}," ++
          s!"\"spent_today_cents\":0,\"created_at\":{jsonEscape created.createdAt}}"))
    else if let some params :=
        (matchRoutePattern? "/api/admin/users/:id/reset-password" rawTarget).orElse
          (fun _ => matchRoutePattern? "/api/admin/users/:id/password" rawTarget) then
      if req.method == "POST" then
        let targetUid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let newPwd := (jv.fieldStr? "password").orElse (fun _ => jv.fieldStr? "new_password") |>.getD ""
        match ← resetUserPasswordRecord st.store targetUid newPwd s!"{nowEpochSec}" with
        | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
        | .ok _ => return .ok (mkJson 200 "{\"ok\":true}")
    else if let some params := matchRoutePattern? "/api/admin/users/:id" rawTarget then
      let targetUid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if req.method == "PATCH" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let newRole? := (jv.fieldStr? "role").map (·.trimAscii.toString.toLower)
        let newUnix? : Option (Option String) :=
          match jv.field? "unix_username" with
          | none => none
          | some .null => some none
          | some (.str s) => some (if s.trimAscii.isEmpty then none else some s.trimAscii.toString)
          | some _ => none
        let newDisabled? := jv.fieldBool? "disabled"
        let newCapRes : Except String (Option (Option UInt64)) :=
          match jv.field? "daily_spend_cap_cents" with
          | none => .ok none
          | some .null => .ok (some none)
          | some _ => (parseOptionalBoundedU64 jv "daily_spend_cap_cents" 0 1000000000).map some
        let .ok newCap? := newCapRes
          | return .ok (mkJson 400 "{\"error\":\"invalid_daily_spend_cap_cents\"}")
        match ← updateUserRecord st.store targetUid newRole? newUnix? newDisabled? newCap? s!"{nowEpochSec}" with
        | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
        | .ok updated =>
          let (infS, cmpS) ← getUserSpentTodayCents st.store updated.id utcDay
          let unixJson := match updated.unixUsername? with | some ux => jsonEscape ux | none => "null"
          let capJson := match updated.dailySpendCapCents? with | some c => s!"{c}" | none => "null"
          let disStr := if updated.disabled then "true" else "false"
          return .ok (mkJson 200 (
            s!"\{\"id\":{jsonEscape updated.id},\"username\":{jsonEscape updated.username},\"role\":{jsonEscape updated.role}," ++
            s!"\"unix_username\":{unixJson},\"disabled\":{disStr},\"daily_spend_cap_cents\":{capJson}," ++
            s!"\"spent_today_cents\":{infS + cmpS},\"created_at\":{jsonEscape updated.createdAt}}"))
      else if req.method == "DELETE" then
        match ← deleteUserRecord st.store caller.userId targetUid with
        | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
        | .ok () =>
          if let some mst := st.managedStore? then
            discard <| execParamQuery mst.db "DELETE FROM user_managed_provider_prefs WHERE user_id=?1;" #[targetUid]
          return .ok (mkJson 200 "{\"ok\":true}")

  -- 6c. Core Workspaces, Nodes & Confined Per-User Uploads (`/api/workspaces`, `/api/nodes`, `/api/machines`, `/api/uploads`)
  if cleanPath == "/api/workspaces" then
    if req.method == "GET" then
      let rows ←
        if caller.isLegacyUnscoped then
          execParamQuery st.store.missionsDb
            "SELECT id,name,path,workspace_type,owner_user_id,created_at FROM workspaces ORDER BY created_at ASC;" #[]
        else
          execParamQuery st.store.missionsDb
            "SELECT id,name,path,workspace_type,owner_user_id,created_at FROM workspaces WHERE owner_user_id=?1 ORDER BY created_at ASC;" #[caller.userId]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      if let some (cCode, cBody) := checkPlacementForCaller caller 0 1 then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let defWid ← nextUniqueId st "ws" nowEpochSec
      let wid := (jv.fieldStr? "id").getD defWid
      let wname := (jv.fieldStr? "name").getD wid
      let wtype := (jv.fieldStr? "workspace_type").getD "host"
      let rawPath := (jv.fieldStr? "path").getD s!"{st.cfg.workingDir}/{wid}"
      let .ok safePath ← confineWorkingDirectory st.cfg.workingDir rawPath
        | return .ok (mkJson 400 "{\"error\":\"invalid_workspace_path\"}")
      match ← execParamQuery st.store.missionsDb
        "INSERT INTO workspaces(id,name,path,workspace_type,owner_user_id,created_at) VALUES(?1,?2,?3,?4,?5,?6);"
        #[wid, wname, safePath, wtype, caller.userId, s!"{nowEpochSec}"] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        return .ok (mkJson 201 s!"\{\"id\":{jsonEscape wid},\"name\":{jsonEscape wname},\"path\":{jsonEscape safePath},\"workspace_type\":{jsonEscape wtype}}")

  if req.method == "GET" && (cleanPath == "/api/nodes" || cleanPath == "/api/machines") then
    let mf ← st.managedRef.get
    let visibleVms :=
      if caller.isLegacyUnscoped then mf.machines
      else mf.machines.filter (fun m => m.ownerUserId == caller.userId)
    let mut items : Array String := #[]
    if caller.role == "admin" then
      items := items.push "{\"id\":\"core\",\"name\":\"orb-core\",\"status\":\"online\",\"admin_only\":true,\"core_colocated\":true}"
    for vm in visibleVms do
      if vm.status != "destroyed" then
        items := items.push s!"\{\"id\":{jsonEscape s!"managed-{vm.id}"},\"name\":{jsonEscape vm.sandboxName},\"provider\":{jsonEscape vm.provider},\"status\":{jsonEscape vm.status},\"admin_only\":false}"
    return .ok (mkJson 200 ("[" ++ String.intercalate "," items.toList ++ "]"))

  if req.method == "POST" && cleanPath == "/api/uploads" then
    let maxUploadBytes : Nat := 16 * 1024 * 1024
    if req.bodySlice.len > maxUploadBytes then
      return .ok (mkJson 413 "{\"error\":\"upload_too_large\"}")
    let uploadOwnerSeg := if caller.userId.isEmpty then "legacy" else caller.userId
    if hasSegmentTraversal uploadOwnerSeg then
      return .ok (mkJson 400 "{\"error\":\"invalid_upload_owner\"}")
    let uploadId ← newUuidV4
    let uploadDir : System.FilePath := System.FilePath.mk st.store.rootDir / "uploads" / uploadOwnerSeg
    if let .error e ← ensurePrivateDir0700 uploadDir then
      return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    let dest := uploadDir / uploadId
    try
      IO.FS.writeBinFile dest req.bodySlice.toByteArray
    catch e =>
      return .ok (mkJson 500 s!"\{\"error\":{jsonEscape s!"upload_write_failed:{e}"}}")
    return .ok (mkJson 201 s!"\{\"id\":{jsonEscape uploadId},\"size\":{req.bodySlice.len},\"owner_user_id\":{jsonEscape uploadOwnerSeg}}")

  -- 6d. Admin-only Backup / Restore / Settings Guards
  if cleanPath == "/api/settings/backup" || cleanPath == "/api/settings/restore" then
    if let some (cCode, cBody) := requireAdminPrincipal caller then
      return .ok (mkJson cCode cBody)
    return .ok (mkJson 200 "{\"ok\":true}")

  -- Mission Automations (`"/api/control/missions/:id/automations"`) + SM-07 wakeup interception
  if let some params := matchRoutePattern? "/api/control/missions/:id/automations" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if let some (cCode, cBody) := (← authorizeMissionOp st caller mid (req.method != "GET")) then
      return .ok (mkJson cCode cBody)
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,cron_expr,prompt,enabled,variables_used,created_at FROM mission_automations WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let some _ ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let bodyVal? := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption
      let tape := JsonTape.indexJsonObject req.bodySlice
      let defAid ← nextUniqueId st "auto" nowEpochSec
      let aid := (JsonTape.lookupString? tape "id").getD defAid
      if let some jv := bodyVal? then
        if isMcpWakeupPayload jv then
          let some draft := parseMcpWakeupPayload? jv mid aid nowEpochSec
            | return .ok (mkJson 400 "{\"error\":\"invalid_wakeup_payload\"}")
          let varGen? := (jv.field? "variables").bind (·.fieldStr? "__wakeup_run_generation") |>.bind String.toNat?
          let callerGen? := ((jv.fieldNat? "run_generation").orElse (fun _ => varGen?)).map Nat.toUInt64
          let isoNow := formatEpochIso8601Utc nowEpochSec
          match ← registerContinuation st.store draft nowEpochSec isoNow callerGen? with
          | .ok cid =>
            let nextAtJson := renderContinuationNextAtJson draft.triggerKind draft.dueEpoch
            return .ok (mkJson 201 s!"\{\"id\":{jsonEscape cid},\"mission_id\":{jsonEscape mid},\"continuation\":true,\"next_at\":{nextAtJson}}")
          | .error "mission_not_found" =>
            return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
          | .error "stale_run_generation" =>
            return .ok (mkJson 409 "{\"error\":\"stale_run_generation\"}")
          | .error "continuation_arm_rejected" | .error "continuation_replace_rejected" =>
            return .ok (mkJson 409 "{\"error\":\"continuation_rejected\"}")
          | .error e =>
            return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      let cron := (JsonTape.lookupString? tape "cron_expr").getD "0 * * * *"
      let prompt :=
        match bodyVal?.bind (·.field? "command_source") |>.bind (·.fieldStr? "content") with
        | some p => p
        | none => (JsonTape.lookupString? tape "prompt").getD ""
      let varsJson := match bodyVal? with | some jv => sanitizeAutomationVariablesJson jv | none => "{}"
      let insRes ← withImmediateTx st.store.missionsDb do
        let mChk ← execParamQueryUnlocked st.store.missionsDb
          "SELECT 1 FROM missions WHERE id=?1 LIMIT 1;" #[mid]
        let .ok mrs := mChk | return .error "mission_select_failed"
        if mrs.size ≤ 1 then return .error "mission_not_found"
        execParamQueryUnlocked st.store.missionsDb
          "INSERT INTO mission_automations(id,mission_id,cron_expr,prompt,enabled,variables_used,created_at) VALUES(?1,?2,?3,?4,1,?5,?6) ON CONFLICT(id) DO UPDATE SET cron_expr=excluded.cron_expr,prompt=excluded.prompt,variables_used=excluded.variables_used WHERE mission_automations.mission_id=excluded.mission_id;"
          #[aid, mid, cron, prompt, varsJson, s!"{nowEpochSec}"]
      match insRes with
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 201 s!"\{\"id\":{jsonEscape aid},\"mission_id\":{jsonEscape mid},\"variables_used\":{varsJson}}")

  -- Continuation Action (`POST /api/control/automations/:id/action`, `SM-07`)
  if let some params := matchRoutePattern? "/api/control/automations/:id/action" rawTarget then
    if req.method == "POST" then
      let cid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !caller.isLegacyUnscoped then
        let cRows ← execParamQuery st.store.missionsDb
          "SELECT mission_id FROM mission_continuations WHERE id=?1 LIMIT 1;" #[cid]
        let cMid? := match cRows with | .ok rs => (rs[1]?.bind (·[0]?)).filter (!·.isEmpty) | .error _ => none
        match cMid? with
        | none => return .ok (mkJson 404 "{\"error\":\"continuation_not_found\"}")
        | some cMid =>
          if let some (cCode, cBody) := (← authorizeMissionOp st caller cMid true) then
            return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let action := (jv.fieldStr? "action").getD ""
      if action != "resume" && action != "cancel" then
        return .ok (mkJson 400 "{\"error\":\"invalid_continuation_action\"}")
      match ← actOnContinuation st.store cid action s!"{nowEpochSec}" nowEpochSec with
      | .ok (.ok mid) =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape cid},\"mission_id\":{jsonEscape mid},\"action\":{jsonEscape action}}")
      | .ok .superseded =>
        return .ok (mkJson 409 "{\"error\":\"continuation_conflict\"}")
      | .error "continuation_not_found" =>
        return .ok (mkJson 404 "{\"error\":\"continuation_not_found\"}")
      | .error "continuation_cancel_race" | .error "stale_run_generation" | .error "continuation_resume_rejected" =>
        return .ok (mkJson 409 "{\"error\":\"continuation_conflict\"}")
      | .error e =>
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Cancel Armed Continuations (`POST /api/control/missions/:id/continuations/cancel`, `SM-07`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/continuations/cancel" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      match ← revokeContinuations st.store mid (formatEpochIso8601Utc nowEpochSec) true with
      | .ok n => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"cancelled\":{n}}")
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Hosted Stop / Cancel vs Local Interrupt (`POST /api/control/missions/:id/stop`, `/cancel`, `/interrupt`, `SM-07`)
  if let some params := (matchRoutePattern? "/api/control/missions/:id/stop" rawTarget).orElse
       (fun _ => matchRoutePattern? "/api/control/missions/:id/cancel" rawTarget) then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let nowIso := formatEpochIso8601Utc nowEpochSec
      discard <| cancelActiveRemoteJobForMission st.store st.managedStore? st.relayHub? mid "Mission stopped on Core"
      match ← hostedStop st.store mid nowIso with
      | .ok gen => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"run_generation\":{gen}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e =>
        if e.startsWith "interrupt_rejected:" || e == "interrupt_cas_lost" || e == "mission_terminal" || e == "fence_cas_lost" then
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Client status change (`POST /api/control/missions/:id/status`): archive (`acknowledged`),
  -- reopen (`paused`, `awaiting_user`) or mark a stopped mission. Never applied over a live run.
  if let some params := matchRoutePattern? "/api/control/missions/:id/status" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let nextStatus := ((jv.fieldStr? "status").getD "").trimAscii.toString
      if encodeRollbackStatus nextStatus == 255 then
        return .ok (mkJson 400 "{\"error\":\"unsupported_status\"}")
      let nowIso := formatEpochIso8601Utc nowEpochSec
      match ← setMissionStatusFromClient st.store mid nextStatus nowIso with
      | .ok changed =>
        if changed then
          -- An archived mission must not be woken again by its own reminders.
          if nextStatus == "acknowledged" then
            discard <| revokeContinuations st.store mid nowIso true
          let payload := renderCompact (.obj #[("status", .str nextStatus), ("mission_id", .str mid)])
          discard <| appendMissionEvent st.store mid "mission_status_changed" payload nowIso
          publishControlEvent st.broadcastHub? "mission_status_changed" payload (some mid)
        return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"status\":{jsonEscape nextStatus}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error "mission_running" =>
        return .ok (mkJson 409 "{\"error\":\"mission_running\",\"message\":\"Stop the mission before changing its status.\"}")
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  if let some params := matchRoutePattern? "/api/control/missions/:id/interrupt" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      match ← reportLocalInterrupt st.store mid s!"{nowEpochSec}" with
      | .ok () => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e =>
        if e.startsWith "interrupt_rejected:" || e == "interrupt_cas_lost" then
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Unified Local + Remote Rate-Limit Park & Resume (`SM-06`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/rate-limit/park" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let notBefore := (jv.fieldNat? "not_before").map Nat.toUInt64 |>.getD 0
      let intent : UInt8 :=
        match jv.fieldBool? "resume_intent" with
        | some b => if b then 1 else 0
        | none => ((jv.fieldNat? "resume_intent").getD 1).toUInt8
      match ← parkRateLimit st.store mid notBefore nowEpochSec intent s!"{nowEpochSec}" with
      | .ok () => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"status\":\"waiting_rate_limit\",\"not_before\":{notBefore},\"resume_intent\":{intent.toNat}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")

  if let some params := matchRoutePattern? "/api/control/missions/:id/rate-limit/resume" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      match ← resumeRateLimit st.store mid nowEpochSec s!"{nowEpochSec}" with
      | .ok () => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"status\":\"active\"}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")

  -- Typed Placement Run Begin (`POST /api/control/missions/:id/runs/begin`, `SM-10`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/runs/begin" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let defRid ← nextUniqueId st "run" nowEpochSec
      let runId := (jv.fieldStr? "run_id").getD defRid
      let callerEp := (jv.fieldNat? "owner_epoch").map Nat.toUInt64 |>.getD 1
      match ← beginMissionRun st.store mid runId s!"{nowEpochSec}" callerEp with
      | .ok res =>
        return .ok (mkJson 201 s!"\{\"run_id\":{jsonEscape res.runId},\"mission_id\":{jsonEscape mid},\"generation\":{res.generation},\"placement_kind\":{jsonEscape res.placementKind}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e =>
        if e.startsWith "invalid_placement_kind:" then
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")

  -- Deferred Goal Structured Trailer Unpack (`POST /api/control/missions/:id/deferred-unpack`, `SM-05`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/deferred-unpack" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let source := (jv.fieldStr? "source").getD "control"
      match ← unpackDeferredGoal st.store mid source s!"{nowEpochSec}" with
      | .ok n => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"unpacked\":{n}}")
      | .error "mission_not_found" => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")

  -- Durable Supervision Counters (`GET|POST /api/control/missions/:id/supervision`, `SM-09`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/supervision" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if let some (cCode, cBody) := (← authorizeMissionOp st caller mid (req.method != "GET")) then
      return .ok (mkJson cCode cBody)
    if req.method == "GET" then
      match ← readSupervision st.store mid with
      | .ok (bg, stArms) =>
        return .ok (mkJson 200 s!"\{\"mission_id\":{jsonEscape mid},\"bg_wait_arms\":{bg},\"stall_consecutive_arms\":{stArms}}")
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let field := (jv.fieldStr? "counter").getD "bg_wait_arms"
      match ← bumpSupervision st.store mid field s!"{nowEpochSec}" with
      | .ok v => return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"counter\":{jsonEscape field},\"value\":{v}}")
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Mission Opened (`POST /api/control/missions/:id/opened`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/opened" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      match ← mark_mission_opened st.store mid (formatEpochIso8601Utc nowEpochSec) with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () => return .ok (mkJson 200 "{\"ok\":true}")

  -- Mission Budget, Reset Cadence, VM Concurrency & Bandwidth Pacing (`GET|PUT /api/control/missions/:id/budget`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/budget" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let some _ ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let mf0 ← st.managedRef.get
      let live ← match st.managedStore? with
        | some mst =>
          match ← loadManagedFleet mst mf0.enabled mf0.boatEnabled mf0.dailyCapCents mf0.spentTodayCents mf0.maxConcurrent with
          | .ok l => st.managedRef.set l; pure l
          | .error _ => pure mf0
        | none => pure mf0
      let cfg ← match st.managedStore? with
        | some mst => getMissionBudgetConfig mst mid
        | none => pure { missionId := mid }
      return .ok (mkJson 200 (renderMissionBudgetJson live cfg nowEpochSec))
    else if req.method == "PUT" || req.method == "PATCH" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let some _ ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let cur ← getMissionBudgetConfig mst mid
      let mut nextCfg := cur
      if let some bv := jv.field? "budget_usd" then
        if bv.isNull then
          nextCfg := { nextCfg with budgetDeciMilliUsd? := none, resetPeriod := "total" }
        else
          match parseDeciMilliUsd? bv 100 1000000000 with
          | some dm => nextCfg := { nextCfg with budgetDeciMilliUsd? := some dm }
          | none =>
            return .ok (mkJson 400 "{\"error\":\"invalid_budget\",\"message\":\"budget_usd must be null or between 0.01 and 100000\"}")
      if let some rpv := jv.field? "budget_reset_period" then
        if !rpv.isNull then
          match rpv.asStr? with
          | some rpRaw =>
            let rp := rpRaw.trimAscii.toString.toLower
            if !isValidBudgetResetPeriod rp then
              return .ok (mkJson 400 "{\"error\":\"invalid_budget_period\",\"message\":\"budget_reset_period must be total, daily, or weekly\"}")
            if nextCfg.budgetDeciMilliUsd?.isNone then
              return .ok (mkJson 400 "{\"error\":\"invalid_budget_period\",\"message\":\"Enable a mission budget (budget_usd) before setting budget_reset_period\"}")
            nextCfg := { nextCfg with resetPeriod := rp }
          | none =>
            return .ok (mkJson 400 "{\"error\":\"invalid_budget_period\",\"message\":\"budget_reset_period must be total, daily, or weekly\"}")
      if let some vmv := jv.field? "vm_limits" then
        match validateVmLimitsPatch vmv with
        | .ok vmJson => nextCfg := { nextCfg with vmLimitsJson := vmJson }
        | .error (errCode, errMsg) =>
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}")
      if let some bwv := jv.field? "bandwidth_limits" then
        match validateBandwidthLimitsPatch bwv with
        | .ok bwJson => nextCfg := { nextCfg with bandwidthLimitsJson := bwJson }
        | .error (errCode, errMsg) =>
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape errCode},\"message\":{jsonEscape errMsg}}")
      nextCfg := { nextCfg with updatedAt := nowEpochSec }
      if let .error e ← saveMissionBudgetConfig mst nextCfg then
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      let mf0 ← st.managedRef.get
      let live ← match ← loadManagedFleet mst mf0.enabled mf0.boatEnabled mf0.dailyCapCents mf0.spentTodayCents mf0.maxConcurrent with
        | .ok l => st.managedRef.set l; pure l
        | .error _ => pure mf0
      let savedCfg ← getMissionBudgetConfig mst mid
      return .ok (mkJson 200 (renderMissionBudgetJson live savedCfg nowEpochSec))

  -- Mission Remote Wait Arm (`POST /api/control/missions/:id/remote-wait`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/remote-wait" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let tape := JsonTape.indexJsonObject req.bodySlice
      let nodeId := (JsonTape.lookupString? tape "node_id").getD ""
      let failedJobId := (JsonTape.lookupString? tape "failed_job_id").getD ""
      let schedOriginJobId := (JsonTape.lookupString? tape "scheduled_origin_job_id").getD ""
      let maxRetries := ((JsonTape.lookupNat? tape "max_retries").getD 10).toUInt32
      let deadlineEpoch := ((JsonTape.lookupNat? tape "deadline_epoch").getD 0).toUInt64
      let termReason := (JsonTape.lookupString? tape "terminal_reason").getD "usage_limit_wait"
      match ← armRemoteMissionWait st.store mid nodeId failedJobId schedOriginJobId maxRetries deadlineEpoch termReason s!"{nowEpochSec}" with
      | .ok () =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"mission_id\":{jsonEscape mid},\"node_id\":{jsonEscape nodeId},\"failed_job_id\":{jsonEscape failedJobId}}")
      | .error "remote_wait_invalid_ids" =>
        return .ok (mkJson 400 "{\"error\":\"remote_wait_invalid_ids\"}")
      | .error e =>
        if e.startsWith "mission_not_found:" then
          return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
        if e.startsWith "remote_wait_rejected:" || e == "remote_wait_cas_lost" then
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Mission Remote Replay Step (`POST /api/control/missions/:id/remote-replay`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/remote-replay" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let bodyVal? := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption
      let tape := JsonTape.indexJsonObject req.bodySlice
      let nodeId := (JsonTape.lookupString? tape "node_id").getD ""
      let defCand ← nextUniqueId st "rjob" nowEpochSec
      let candidateJobId := (JsonTape.lookupString? tape "candidate_job_id").getD defCand
      let isSched := (bodyVal?.bind (·.fieldBool? "scheduled_origin")).getD false
      let dispatchOutcome := ((JsonTape.lookupNat? tape "dispatch_outcome").getD 0).toUInt8
      let hasRecHandle := ((JsonTape.lookupNat? tape "has_recovery_handle").getD 0).toUInt8
      let retryFits := ((JsonTape.lookupNat? tape "retry_fits_deadline").getD 1).toUInt8
      match ← stepRemoteMissionReplay st.store mid nodeId candidateJobId isSched dispatchOutcome hasRecHandle retryFits nowEpochSec s!"{nowEpochSec}" with
      | .ok rec =>
        let waitStr := if rec.waitActive then "true" else "false"
        return .ok (mkJson 200 (
          s!"\{\"action\":{rec.action},\"verdict\":{rec.verdict},\"status\":{jsonEscape rec.missionStatus}," ++
          s!"\"terminal_reason\":{jsonEscape rec.terminalReason},\"placement_job_id\":{jsonEscape rec.placementJobId}," ++
          s!"\"scheduled_remote_job_id\":{jsonEscape rec.scheduledRemoteJobId},\"failed_job_id\":{jsonEscape rec.failedJobId}," ++
          s!"\"retries\":{rec.retries},\"replays\":{rec.replays},\"wait_active\":{waitStr}}"
        ))
      | .error "scheduled_recovery_superseded" =>
        return .ok (mkJson 409 "{\"error\":\"scheduled_recovery_superseded\"}")
      | .error "scheduled_recovery_missing_remote_job" =>
        return .ok (mkJson 400 "{\"error\":\"scheduled_recovery_missing_remote_job\"}")
      | .error "remote_wait_not_armed" =>
        return .ok (mkJson 404 "{\"error\":\"remote_wait_not_armed\"}")
      | .error "remote_replay_missing_candidate_job" =>
        return .ok (mkJson 400 "{\"error\":\"remote_replay_missing_candidate_job\"}")
      | .error "remote_replay_invalid_flags" =>
        return .ok (mkJson 400 "{\"error\":\"remote_replay_invalid_flags\"}")
      | .error e =>
        if e.startsWith "mission_not_found:" then
          return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
        if e.startsWith "remote_replay_lifecycle_rejected:" || e == "remote_replay_cas_lost" ||
           e == "remote_replay_run_lifecycle_rejected" || e == "remote_replay_rollback_lifecycle_rejected" ||
           e == "remote_replay_fail_lifecycle_rejected" || e == "remote_replay_rollback_invariant_failed" then
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Stranded Pending & Shared Startup/Runtime Reconciliation (`POST /api/control/missions/reconcile-pending`, `POST /api/control/missions/reconcile`)
  if req.method == "POST" && cleanPath == "/api/control/missions/reconcile-pending" then
    if !caller.isLegacyUnscoped then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
    match ← reconcileStrandedPendingMissions st.store.missionsDb s!"{nowEpochSec}" with
    | .ok n => return .ok (mkJson 200 s!"\{\"ok\":true,\"healed\":{n}}")
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  if req.method == "POST" && cleanPath == "/api/control/missions/reconcile" then
    if !caller.isLegacyUnscoped then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
    match ← runSharedReconcile st.store s!"{nowEpochSec}" with
    | .ok n => return .ok (mkJson 200 s!"\{\"ok\":true,\"reconciled\":{n}}")
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Side-Question Context Staging (`POST /api/control/missions/:id/btw/context`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/btw/context" rawTarget then
    if req.method == "POST" then
      let srcMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller srcMid true) then
        return .ok (mkJson cCode cBody)
      let some _ ← getMission? st.store srcMid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let manifestId := ((jv.fieldStr? "manifest_id").getD "").trimAscii.toString
      if manifestId.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_manifest_id\"}")
      return .ok (mkJson 200 "{\"ok\":true}")

  -- Side-Question Child Agent (`POST /api/control/missions/:id/btw/agent`)
  -- Read-only `/btw` side sessions bypass project `parallel_missions_cap` and track leases.
  if let some params := matchRoutePattern? "/api/control/missions/:id/btw/agent" rawTarget then
    if req.method == "POST" then
      let srcMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller srcMid true) then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let hdrIdemKey := (lookupHeaderCI req.headers "idempotency-key").map (·.trimAscii.toString) |>.getD ""
      let bodyIdemKey := ((jv.fieldStr? "idempotency_key").getD "").trimAscii.toString
      let idemKey := if !hdrIdemKey.isEmpty then hdrIdemKey else bodyIdemKey
      if idemKey.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_idempotency_key\"}")
      let idemScope := s!"btw_agent:{srcMid}"
      match ← claimIdempotencySlot st.store idemScope idemKey s!"{nowEpochSec}" with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok (.Replayed rec) => return .ok (mkJson rec.statusCode rec.bodyJson)
      | .ok .InFlight => return .ok (mkJson 409 "{\"error\":\"idempotency_key_in_flight\"}")
      | .ok .Claimed => pure ()
      let abortBtwIdem : IO Unit :=
        discard <| abortIdempotencySlot st.store idemScope idemKey
      let reqBackend? := jv.fieldStr? "backend"
      let reqModelOv? := jv.fieldStr? "model_override"
      let rawEffort? := jv.fieldStr? "model_effort"
      if let some re := rawEffort? then
        let trimmedRe := re.trimAscii.toString
        if !trimmedRe.isEmpty then
          let checkBack := reqBackend?.orElse (fun _ => some "codex")
          if (normalizeModelEffortForBackend checkBack trimmedRe).isNone then
            abortBtwIdem
            return .ok (mkJson 400 s!"\{\"error\":\"unsupported_model_effort\",\"effort\":{jsonEscape trimmedRe}}")
      let sidePrompt? := (jv.fieldStr? "side_question").orElse (fun _ => jv.fieldStr? "prompt")
      let ctxMode := ((jv.fieldStr? "side_context_mode").getD "").trimAscii.toString.toLower
      let defaultSafeBase ← do
        match ← confineWorkingDirectory st.cfg.workingDir st.cfg.workingDir with
        | .ok b => pure b
        | .error _ => pure st.cfg.workingDir
      let defNewId ← newUuidV4
      let newMid := (jv.fieldStr? "id").getD defNewId
      if !isSafeMissionId newMid then
        abortBtwIdem
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      let nowIso := formatEpochIso8601Utc nowEpochSec
      let explicitBtwRn? := (jv.fieldStr? "remote_node_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let inheritedBtwRn? ←
        if explicitBtwRn?.isSome then pure explicitBtwRn?
        else resolveMissionRemoteNode? st.store st.managedStore? srcMid
      let forkReq : ForkMissionRequest := {
        sourceMissionId := srcMid
        newMissionId := newMid
        targetBackend? := reqBackend?
        modelOverride? := reqModelOv?
        modelEffort? := rawEffort?.map (fun s => s.trimAscii.toString.toLower) |>.filter (!·.isEmpty)
        remoteNodeId? := inheritedBtwRn?
        sideQuestion := true
        sidePrompt? := sidePrompt?
        incrementalSide := ctxMode == "incremental"
        ownerUserId := caller.userId
        nowAt := nowIso
      }
      match ← forkOrHandoffMission st.store defaultSafeBase forkReq with
      | .error (code, msg) =>
        abortBtwIdem
        return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
      | .ok out =>
        let cleanupUnbornBtw : IO Unit := do
          discard <| execParamQuery st.store.missionsDb "DELETE FROM mission_events WHERE mission_id=?1;" #[out.missionId]
          discard <| execParamQuery st.store.missionsDb "DELETE FROM mission_runs WHERE mission_id=?1;" #[out.missionId]
          discard <| execParamQuery st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[out.missionId]
          abortBtwIdem
        let sideQuestionText := (sidePrompt?.getD "").trimAscii.toString
        let mut effStatus := "awaiting_user"
        if !sideQuestionText.isEmpty && out.placementKind != "client" then
          -- When full transcript turns were copied (`turnsCopied > 1`), include parent history in initial turn prompt
          let mut turnPrompt := sideQuestionText
          if out.turnsCopied > 1 then
            let pTurns ← loadCanonicalMissionTurns st.store srcMid false
            if !pTurns.isEmpty then
              let lines := pTurns.map fun (r, c) =>
                s!"[{(if r == "user" then "User" else "Assistant")}]\n{c}"
              turnPrompt :=
                "Parent mission conversation context:\n\n" ++
                String.intercalate "\n\n---\n\n" lines.toList ++
                "\n\n---\n\nSide question (read-only `/btw`):\n" ++ sideQuestionText
          match out.remoteNodeId? with
          | some targetNode =>
            if let some sup := st.remoteSup? then
              let effModel :=
                if out.backend == "opencode" && out.modelOverride.trimAscii.toString.isEmpty then "builtin/smart"
                else out.modelOverride
              let spec : RemoteTurnSpec := {
                missionId        := out.missionId
                targetNodeId     := targetNode
                backend          := out.backend
                modelOverride    := effModel
                modelEffort      := out.modelEffort
                workingDirectory := out.workingDirectory
                project          := out.project
                ownerUserId      := caller.userId
                authorityMode    := "readonly"
                placementKind    := out.placementKind
                tagsJson         := out.tagsJson
                prompt           := turnPrompt
                sideQuestion     := true
                companionOf?     := some srcMid
              }
              match ← submitRemoteMissionTurn st.store st.managedStore? st.relayHub? st.broadcastHub? sup st.cfg.workingDir spec nowEpochSec with
              | .ok _ => effStatus := "active"
              | .error dispErr =>
                cleanupUnbornBtw
                return .ok (mkJson 502 s!"\{\"error\":{jsonEscape dispErr}}")
          | none =>
            if st.warmMgr?.isSome then
              let effModel :=
                if out.backend == "opencode" && out.modelOverride.trimAscii.toString.isEmpty then "builtin/smart"
                else out.modelOverride
              match ← launchLocalCoreMissionTurn st out.missionId out.backend out.workingDirectory turnPrompt effModel out.modelEffort "bypassPermissions" none "local" false with
              | .ok _ => effStatus := "active"
              | .error launchErr =>
                cleanupUnbornBtw
                return .ok (mkJson 502 s!"\{\"error\":{jsonEscape launchErr}}")
        let rnJson := match out.remoteNodeId? with | some rn => jsonEscape rn | none => "null"
        let modOvJson := if out.modelOverride.isEmpty then "null" else jsonEscape out.modelOverride
        let effJson := if out.modelEffort.isEmpty then "null" else jsonEscape out.modelEffort
        let projField := if out.project.isEmpty then "" else s!",\"project\":{jsonEscape out.project}"
        let body :=
          s!"\{\"id\":{jsonEscape out.missionId},\"title\":{jsonEscape out.title},\"status\":{jsonEscape effStatus}," ++
          s!"\"backend\":{jsonEscape out.backend},\"model_override\":{modOvJson},\"model_effort\":{effJson}," ++
          s!"\"authority_mode\":\"readonly\",\"working_directory\":{jsonEscape out.workingDirectory},\"remote_node_id\":{rnJson}," ++
          s!"\"placement_kind\":{jsonEscape out.placementKind}{projField},\"created_at\":{jsonEscape nowIso},\"updated_at\":{jsonEscape nowIso},\"state_revision\":1,\"tags\":{out.tagsJson}}"
        match ← recordOrReplayIdempotency st.store idemScope idemKey 201 body nowIso with
        | .ok rec => return .ok (mkJson rec.statusCode rec.bodyJson)
        | .error e =>
          cleanupUnbornBtw
          return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Mission Fork & Cloud-to-Workspace Handoff (`POST /api/control/missions/:id/fork`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/fork" rawTarget then
    if req.method == "POST" then
      let srcMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller srcMid true) then
        return .ok (mkJson cCode cBody)
      let jv :=
        if req.bodySlice.len == 0 then JVal.obj #[]
        else match OrbBin.Json.parseBytes req.bodySlice.toByteArray with
          | .ok v => v
          | .error _ => .null
      if jv == .null then
        return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let defNewId ← newUuidV4
      let newMid := (jv.fieldStr? "id").getD defNewId
      let reqBackend? := jv.fieldStr? "backend"
      let reqModelOv? := jv.fieldStr? "model_override"
      let rawEffort? := jv.fieldStr? "model_effort"
      if let some re := rawEffort? then
        let trimmedRe := re.trimAscii.toString
        if !trimmedRe.isEmpty then
          let checkBack := reqBackend?.orElse (fun _ => some "codex")
          if (normalizeModelEffortForBackend checkBack trimmedRe).isNone then
            return .ok (mkJson 400 s!"\{\"error\":\"unsupported_model_effort\",\"effort\":{jsonEscape trimmedRe}}")
      let explicitForkRn? := (jv.fieldStr? "remote_node_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let rawWd? := jv.fieldStr? "working_directory"
      let remoteNodeId? ←
        if explicitForkRn?.isSome then pure explicitForkRn?
        else if rawWd?.isNone then resolveMissionRemoteNode? st.store st.managedStore? srcMid
        else pure none
      let isRemoteTarget :=
        match remoteNodeId? with
        | some rn =>
          let t := rn.trimAscii.toString
          !t.isEmpty && t != "local"
        | none => false
      let (forkTKind, forkNAdmin) :=
        classifyMissionPlacementTarget false (if isRemoteTarget then "remote" else "local") remoteNodeId?
      if let some (cCode, cBody) := checkPlacementForCaller caller forkTKind forkNAdmin then
        return .ok (mkJson cCode cBody)
      let confinedWdRes : Except String (Option String) ← do
        match rawWd? with
        | none => pure (.ok none)
        | some wd =>
          let t := wd.trimAscii.toString
          if t.isEmpty then pure (.ok none)
          else if isRemoteTarget then
            if t.toList.any (fun c => c.toNat == 0) || (t.splitOn "/").any (· == "..") then
              pure (.error "invalid_working_directory")
            else
              pure (.ok (some t))
          else
            match ← confineWorkingDirectory st.cfg.workingDir t with
            | .ok safe => pure (.ok (some safe))
            | .error e => pure (.error e)
      let .ok safeWd? := confinedWdRes
        | return .ok (mkJson 400 "{\"error\":\"invalid_working_directory\"}")
      let defaultSafeBase ← do
        match ← confineWorkingDirectory st.cfg.workingDir st.cfg.workingDir with
        | .ok b => pure b
        | .error _ => pure st.cfg.workingDir
      let sideQ := (jv.fieldBool? "side_question").getD false
      let sidePrompt? := jv.fieldStr? "prompt"
      let nowIso := formatEpochIso8601Utc nowEpochSec
      let forkReq : ForkMissionRequest := {
        sourceMissionId := srcMid
        newMissionId := newMid
        targetBackend? := reqBackend?
        modelOverride? := reqModelOv?
        modelEffort? := rawEffort?.map (fun s => s.trimAscii.toString.toLower)
        workingDir? := safeWd?
        remoteNodeId? := remoteNodeId?
        title? := jv.fieldStr? "title"
        sideQuestion := sideQ
        sidePrompt? := sidePrompt?
        ownerUserId := caller.userId
        nowAt := nowIso
      }
      match ← forkOrHandoffMission st.store defaultSafeBase forkReq with
      | .error (code, msg) =>
        return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
      | .ok out =>
        if let some sIdx := st.searchIdx? then
          discard <| indexConversation sIdx out.missionId out.title
        let rnJson := match out.remoteNodeId? with | some rn => jsonEscape rn | none => "null"
        let modOvJson := if out.modelOverride.isEmpty then "null" else jsonEscape out.modelOverride
        let effJson := if out.modelEffort.isEmpty then "null" else jsonEscape out.modelEffort
        let cloudTurnsStr := if out.usedCloudTurns then "true" else "false"
        let freshWsStr := if out.freshWorkspace then "true" else "false"
        let dispForkProj :=
          if out.project.isEmpty then "null"
          else if caller.isLegacyUnscoped then jsonEscape out.project
          else if out.project.startsWith (caller.userId ++ ":") then jsonEscape (out.project.drop (caller.userId.length + 1)).toString
          else jsonEscape out.project
        let body :=
          s!"\{\"id\":{jsonEscape out.missionId},\"title\":{jsonEscape out.title},\"status\":\"awaiting_user\"," ++
          s!"\"backend\":{jsonEscape out.backend},\"model_override\":{modOvJson},\"model_effort\":{effJson}," ++
          s!"\"project\":{dispForkProj},\"folder\":{jsonEscape out.folder},\"placement_revision\":1," ++
          s!"\"working_directory\":{jsonEscape out.workingDirectory},\"remote_node_id\":{rnJson}," ++
          s!"\"placement_kind\":{jsonEscape out.placementKind}," ++
          s!"\"forked_from\":{jsonEscape out.forkedFrom},\"turns_copied\":{out.turnsCopied}," ++
          s!"\"used_cloud_turns\":{cloudTurnsStr},\"fresh_workspace\":{freshWsStr}," ++
          s!"\"state_revision\":1,\"tags\":{out.tagsJson}}"
        return .ok (mkJson 201 body)

  -- Mission Machine Transfer (`GET|POST /api/control/missions/:id/machine-transfer`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/machine-transfer" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if let some (cCode, cBody) := (← authorizeMissionOp st caller mid (req.method != "GET")) then
      return .ok (mkJson cCode cBody)
    if req.method == "GET" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,mission_id,phase,revision,created_at FROM machine_transfers WHERE mission_id=?1 ORDER BY created_at ASC;" #[mid]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if req.method == "POST" then
      let tape := JsonTape.indexJsonObject req.bodySlice
      let dest := (JsonTape.lookupString? tape "destination").getD "local"
      let (txTKind, txNAdmin) := classifyMissionPlacementTarget (dest == "client") "remote" (some dest)
      if let some (cCode, cBody) := checkPlacementForCaller caller txTKind txNAdmin then
        return .ok (mkJson cCode cBody)
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

  -- Mission Shares (`GET|POST /api/control/missions/:id/shares`, `DELETE /api/control/missions/:id/shares/:user_id`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/shares/:user_id" rawTarget then
    if req.method == "DELETE" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let targetUid := (params.find? (fun p => p.1 == "user_id")).map Prod.snd |>.getD ""
      if !caller.isLegacyUnscoped then
        let (exists_, isOwner, isPart) ← getMissionRelationship st.store mid caller.userId
        if !exists_ || (!isOwner && !isPart) then
          return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
        if !isOwner && targetUid != caller.userId then
          return .ok (mkJson 403 "{\"error\":\"owner_required\"}")
      match ← removeMissionShareRecord st.store mid targetUid with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 200 "{\"ok\":true}")

  if let some params := matchRoutePattern? "/api/control/missions/:id/shares" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      match ← listMissionSharesJson st.store mid with
      | .ok body => return .ok (mkJson 200 body)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let uname := ((jv.fieldStr? "username").getD "").trimAscii.toString
      if uname.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_username\"}")
      let some mRec ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let effOwnerId := if !mRec.ownerUserId.isEmpty then mRec.ownerUserId else caller.userId
      match ← addMissionShareByUsername st.store mid effOwnerId uname s!"{nowEpochSec}" with
      | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
      | .ok sh =>
        return .ok (mkJson 201 s!"\{\"mission_id\":{jsonEscape sh.missionId},\"user_id\":{jsonEscape sh.userId},\"username\":{jsonEscape sh.username},\"created_at\":{jsonEscape sh.createdAt}}")

  -- Mission Archive (`POST /api/control/missions/:id/archive`) & Mission Proxy Token (`POST /api/control/missions/:id/proxy-token`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/archive" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let arch := (jv.fieldBool? "archived").getD true
      let some mRec ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let curTags : Array String :=
        match OrbBin.Json.parse mRec.tagsJson with
        | .ok (.arr xs) => xs.filterMap JVal.asStr?
        | _ => #[]
      let nextTags :=
        let base := curTags.filter (· != "archived")
        if arch then base.push "archived" else base
      let nextTagsJson := "[" ++ String.intercalate "," (nextTags.toList.map jsonEscape) ++ "]"
      match ← execParamQuery st.store.missionsDb
        "UPDATE missions SET tags=?2, state_revision=state_revision+1, updated_at=?3 WHERE id=?1;"
        #[mid, nextTagsJson, formatEpochIso8601Utc nowEpochSec] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape mid},\"archived\":{if arch then "true" else "false"}}")

  if let some params := matchRoutePattern? "/api/control/missions/:id/proxy-token" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let some mRec ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let ownerUid := if !mRec.ownerUserId.isEmpty then mRec.ownerUserId else caller.userId
      let exp := nowEpochSec + 86400
      match ← mintMissionProxyToken st.store mid ownerUid exp with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok pTok =>
        return .ok (mkJson 201 s!"\{\"mission_id\":{jsonEscape mid},\"token\":{jsonEscape pTok},\"expires_at\":{exp}}")

  -- Mission Messages & Files (`GET /api/control/missions/:id/messages`, `/files`; `/events` handled by cursor-paginated `X-Orb-Events-Protocol: 1` below)
  if let some params := matchRoutePattern? "/api/control/missions/:id/messages" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let effSeqExpr := "(CASE WHEN COALESCE(seq,0)>0 THEN seq ELSE COALESCE(sequence,0) END)"
      let rows ← execParamQuery st.store.missionsDb
        (s!"SELECT {effSeqExpr} AS seq, event_type, " ++
         "CASE WHEN COALESCE(payload,'')<>'' AND COALESCE(payload,'')<>'{}' THEN payload ELSE json_object('content',COALESCE(content,'')) END AS payload, " ++
         s!"COALESCE(NULLIF(created_at,''),timestamp,'') AS created_at FROM mission_events WHERE mission_id=?1 AND event_type='user_message' ORDER BY {effSeqExpr} ASC, id ASC;") #[mid]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))

  if let some params := matchRoutePattern? "/api/control/missions/:id/files" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      return .ok (mkJson 200 "{\"entries\":[]}")

  -- Mission Health Verdict (`GET /api/control/missions/:id/health`, `SM-01`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/health" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let sql :=
        "SELECT m.status,COALESCE(m.terminal_reason,''),m.orphaned_at,m.superseded_by_mission_id," ++
        "m.placement_kind,m.node_boot_epoch,m.state_revision," ++
        "COALESCE(e.terminal_reason,''),COALESCE(e.summary,''),COALESCE(e.artifact_ref,''),COALESCE(e.recorded_at,'')," ++
        "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal')," ++
        "(SELECT COUNT(*) FROM mission_events ev WHERE ev.mission_id=m.id)," ++
        "(SELECT COUNT(*) FROM mission_continuations c WHERE c.mission_id=m.id AND c.phase=1)," ++
        "COALESCE(e.verified,1) " ++
        "FROM missions m LEFT JOIN mission_terminal_evidence e ON e.mission_id = m.id WHERE m.id=?1;"
      match ← execParamQuery st.store.missionsDb sql #[mid] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok rs =>
        if rs.size ≤ 1 then
          return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
        let r := rs[1]!
        let status := r[0]?.getD ""
        let mReason := r[1]?.getD ""
        let orphAt := r[2]?.getD ""
        let superBy := r[3]?.getD ""
        let placeKind := r[4]?.getD "managed"
        let rowBoot := ((r[5]?.bind String.toNat?).getD 1).toUInt64
        let stateRev := (r[6]?.bind String.toNat?).getD 1
        let evReason := r[7]?.getD ""
        let evSummary := r[8]?.getD ""
        let evArtifact := r[9]?.getD ""
        let evRecorded := r[10]?.getD ""
        let liveRuns := (r[11]?.bind String.toNat?).getD 0
        let evCnt := (r[12]?.bind String.toNat?).getD 0
        let armedWakeups := (r[13]?.bind String.toNat?).getD 0
        let evVerified := ((r[14]?.bind String.toNat?).getD 1) != 0
        let effReason := if !evReason.isEmpty then evReason else mReason
        let hasEv := !evRecorded.isEmpty || !evReason.isEmpty
        let verdict := deriveMissionHealthVerdict
          status effReason orphAt superBy placeKind
          (rowBoot == st.store.bootEpoch) false (liveRuns > 0) (evCnt > 0) (armedWakeups > 0) hasEv
        let evJson :=
          if hasEv then
            s!"\{\"terminal_reason\":{jsonEscape evReason},\"summary\":{jsonEscape evSummary},\"artifact_ref\":{jsonEscape evArtifact},\"verified\":{if evVerified then "true" else "false"},\"recorded_at\":{jsonEscape evRecorded}}"
          else "null"
        let (bgArms, stallArms) ← match ← readSupervision st.store mid with | .ok p => pure p | .error _ => pure (0, 0)
        return .ok (mkJson 200 (
          s!"\{\"mission_id\":{jsonEscape mid},\"status\":{jsonEscape status},\"health_verdict\":{jsonEscape verdict}," ++
          s!"\"state_revision\":{stateRev},\"bg_wait_arms\":{bgArms},\"stall_consecutive_arms\":{stallArms},\"terminal_evidence\":{evJson}}"
        ))

  -- Missions Collection (`GET|POST /api/control/missions`)
  if cleanPath == "/api/control/missions" then
    if req.method == "GET" then
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      let qParams := parseQueryParams rawTarget
      let qLookup (k : String) : Option String :=
        (qParams.find? (fun p => p.1 == k)).bind (fun p => percentDecodeStrict p.2)
      let rawProjF? := (qLookup "project").orElse (fun _ => qLookup "project_slug")
      let unassignedOnly := (qLookup "unassigned") == some "true" || rawProjF? == some "__unassigned__"
      let statusRaw := (qLookup "status").getD ""
      let statusesArr :=
        if statusRaw.trimAscii.toString.isEmpty then #[]
        else (statusRaw.splitOn ",").toArray.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let allParam? := (qLookup "all").map (·.trimAscii.toString.toLower)
      let includeArchived := allParam? == some "true" || allParam? == some "1"
      let filter : MissionListFilter := {
        limit?           := (qLookup "limit").bind String.toNat?
        offset?          := (qLookup "offset").bind String.toNat?
        updatedSince?    := (qLookup "updated_since").orElse (fun _ => qLookup "since_updated_at")
        statusesFilter   := statusesArr
        includeArchived  := includeArchived
        bootstrapAdminId := st.bootstrapAdminId
        project?         := if unassignedOnly then none else rawProjF?.filter (!·.isEmpty)
        unassignedOnly   := unassignedOnly
        folder?          := (qLookup "folder").map normalizeMissionFolder
        folderPrefix?    := (qLookup "folder_prefix").map normalizeMissionFolder
        track?           := (qLookup "track").filter (!·.isEmpty)
        tag?             := (qLookup "tag").filter (!·.isEmpty)
        originSessionId? := (qLookup "origin_session_id").filter (!·.isEmpty)
        workspaceId?     := (qLookup "workspace_id").filter (!·.isEmpty)
      }
      match ← listMissionsJson st.store none callerOpt filter with
      | .ok j => return .ok (mkJson 200 j)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let bodyVal? := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption
      if let some bJv := bodyVal? then
        if let some cloudSel := bJv.field? "cloud" then
          if !cloudSel.isNull then
            let cHub ← match st.cloudHub? with | some h => pure h | none => newCloudRuntimeHub
            let (cCode, cCtype, cBody) ← handleCloudMissionCreate
              cHub st.store st.broadcastHub? st.cfg.port
              caller.userId caller.username st.bootstrapAdminId
              (caller.isLegacyUnscoped || caller.role == "admin") caller.isLegacyUnscoped
              bJv cloudSel
            return .ok { status := cCode, contentType := cCtype, corsOrigin? := reqOrigin?, body := cBody }
      let hdrIdemKey := (lookupHeaderCI req.headers "idempotency-key").map (·.trimAscii.toString) |>.getD ""
      let bodyIdemKey := (bodyVal?.bind (·.fieldStr? "idempotency_key")).map (·.trimAscii.toString) |>.getD ""
      let idemKey := if !hdrIdemKey.isEmpty then hdrIdemKey else bodyIdemKey
      if !idemKey.isEmpty then
        match ← claimIdempotencySlot st.store "missions_create" idemKey s!"{nowEpochSec}" with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok (.Replayed rec) => return .ok (mkJson rec.statusCode rec.bodyJson)
        | .ok .InFlight => return .ok (mkJson 409 "{\"error\":\"idempotency_key_in_flight\"}")
        | .ok .Claimed => pure ()
      let abortIdem : IO Unit :=
        if !idemKey.isEmpty then discard <| abortIdempotencySlot st.store "missions_create" idemKey else pure ()
      let tape := JsonTape.indexJsonObject req.bodySlice
      let defMid ← newUuidV4
      let mid := (JsonTape.lookupString? tape "id").getD defMid
      if !isSafeMissionId mid then
        abortIdem
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      let title := (JsonTape.lookupString? tape "title").getD "New Mission"
      let backend := (JsonTape.lookupString? tape "backend").getD "codex"
      let rawEffort := (JsonTape.lookupString? tape "model_effort").getD ""
      let normEffort ←
        if rawEffort.trimAscii.toString.isEmpty then pure ""
        else match normalizeModelEffortForBackend (some backend) rawEffort with
          | some eff => pure eff
          | none => pure "__REJECT_EFFORT__"
      if normEffort == "__REJECT_EFFORT__" then
        abortIdem
        return .ok (mkJson 400 s!"\{\"error\":\"unsupported_model_effort\",\"backend\":{jsonEscape backend},\"effort\":{jsonEscape rawEffort}}")
      let rawProjSlug := ((JsonTape.lookupString? tape "project_slug").orElse (fun _ => JsonTape.lookupString? tape "project")).getD ""
      let projSlugRes : Except String String :=
        if rawProjSlug.isEmpty || caller.isLegacyUnscoped then .ok rawProjSlug
        else match scopeProjectSlug caller.userId st.bootstrapAdminId rawProjSlug with
          | some sp => .ok sp
          | none => .error "invalid_project"
      let .ok projSlug := projSlugRes
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
      let track := (JsonTape.lookupString? tape "track").getD ""
      let repo := ((JsonTape.lookupString? tape "github_pr").orElse (fun _ => JsonTape.lookupString? tape "repo")).getD ""
      let rawDiskNat := (JsonTape.lookupNat? tape "estimated_disk_gib").getD 0
      if rawDiskNat > maxReservedDiskGib.toNat then
        abortIdem
        return .ok (mkJson 400 "{\"error\":\"invalid_estimated_disk_gib\"}")
      let diskGib := rawDiskNat.toUInt64
      let writerFlag? := bodyVal?.bind (·.fieldBool? "writer")
      let baseReqTags : Array String :=
        match bodyVal?.bind (·.fieldArr? "tags") with
        | some xs => xs.filterMap (fun v => match v with | .str s => some s | _ => none)
        | none => #[]
      let remoteNodeId? := (JsonTape.lookupString? tape "remote_node_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      let reqTags : Array String :=
        match remoteNodeId? with
        | some rn =>
          if baseReqTags.any (·.startsWith "remote-node:") then baseReqTags
          else baseReqTags.push s!"remote-node:{rn}"
        | none => baseReqTags
      let placement? := JsonTape.lookupString? tape "placement"
      let clientPlaced := isClientPlacement placement? reqTags
      let rawPlaceKind? := JsonTape.lookupString? tape "placement_kind"
      let prelimPlaceKind :=
        match rawPlaceKind? with
        | some pk => pk.trimAscii.toString.toLower
        | none => if clientPlaced then "client" else "managed"
      if let some _ := rawPlaceKind? then
        if prelimPlaceKind != "managed" && prelimPlaceKind != "managed_vm" && !(prelimPlaceKind.startsWith "managed-") &&
           prelimPlaceKind != "client" && prelimPlaceKind != "local" && prelimPlaceKind != "remote" && prelimPlaceKind != "remote_node" then
          abortIdem
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape s!"invalid_placement_kind:{prelimPlaceKind}"}}")
      let (tKind, nAdmin) := classifyMissionPlacementTarget clientPlaced prelimPlaceKind remoteNodeId? reqTags
      if let some (cCode, cBody) := checkPlacementForCaller caller tKind nAdmin then
        abortIdem
        return .ok (mkJson cCode cBody)
      let placeKind :=
        match rawPlaceKind? with
        | some _ => if tKind == 3 then "managed_vm" else prelimPlaceKind
        | none => if clientPlaced then "client" else if tKind == 3 then "managed_vm" else "managed"
      let explicitWorkDir? := JsonTape.lookupString? tape "working_directory"
      let rawWorkDir := explicitWorkDir?.getD st.cfg.workingDir
      let safeWorkDirRes : Except String String ← do
        if tKind != 0 && explicitWorkDir?.isNone && !clientPlaced then
          pure (.ok "")
        else if tKind != 0 && explicitWorkDir?.isSome then
          let t := rawWorkDir.trimAscii.toString
          if t.isEmpty || t.toList.any (fun c => c.toNat == 0) || (t.splitOn "/").any (· == "..") then
            pure (.error "invalid_working_directory")
          else
            pure (.ok t)
        else
          confineWorkingDirectory st.cfg.workingDir rawWorkDir
      let .ok safeWorkDir := safeWorkDirRes
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"invalid_working_directory\"}")
      let intentStr := (JsonTape.lookupString? tape "intent").getD ""
      let .ok authMode := classifyAuthorityMode writerFlag? reqTags (intentStr == "review_only" || intentStr == "readonly")
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"contradictory_authority_tags\"}")
      let bodyJv := bodyVal?.getD (.obj #[])
      let modelOverride := (JsonTape.lookupString? tape "model_override").getD ""
      let prompt? := JsonTape.lookupString? tape "prompt"
      let mut selectedSkills : Array SelectedSkill := #[]
      if !clientPlaced then
        if let some prompt := prompt? then
          match ← selectDelivered st.cfg.workingDir (if rawProjSlug.isEmpty then none else some rawProjSlug) backend prompt with
          | .error e =>
            abortIdem
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          | .ok selected =>
            selectedSkills := selected
            if remoteNodeId?.isSome then
              for sk in selected do
                if !remoteInstallable sk.name then
                  let errMsg := s!"Skill cannot be installed by the remote skill installer: {sk.name}"
                  abortIdem
                  return .ok (mkJson 400 s!"\{\"error\":{jsonEscape errMsg}}")
      let cyberMode ← match JsonTape.lookupString? tape "cyber_access" with
        | none => pure Mode.automatic
        | some rawMode =>
          match parseMode? rawMode with
          | some m => pure m
          | none =>
            abortIdem
            return .ok (mkJson 400 "{\"error\":\"invalid_cyber_mode\"}")
      if backend != "codex" && cyberMode != .automatic then
        abortIdem
        return .ok (mkJson 400 "{\"error\":\"Cyber selection is available for Codex only.\"}")
      if backend == "codex" then
        if let some prompt := prompt? then
          if let .error e := validateGoalMessage prompt (bodyHasImages bodyJv) then
            abortIdem
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        let effectiveModel := if modelOverride.isEmpty then defaultCodexModel else modelOverride
        if let .error e := cyberMode.program effectiveModel then
          abortIdem
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        if let .error e := validateGoalSelection cyberMode (prompt?.bind parseGoalPrefix?).isSome then
          abortIdem
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
      let isBtwReq :=
        reqTags.any isBtwMissionTag ||
        ((bodyVal?.bind (·.fieldBool? "side_question")).getD false)
      if !projSlug.isEmpty then
        if !caller.isLegacyUnscoped && !caller.userId.isEmpty then
          discard <| execParamQuery st.store.projectsDb
            "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
            #[projSlug, caller.userId, s!"{nowEpochSec}"]
        if !isBtwReq then
          let rawCap? ← queryProjectParallelMissions? st.store projSlug
          if let some cap := enforcedProjectParallelCap? rawCap? then
            if let .ok statuses ← listProjectMissionStatuses st.store projSlug then
              let held := (statuses.filter campaignSlotHeldBy).size
              if held ≥ cap then
                abortIdem
                return .ok (mkJson 429 s!"\{\"error\":\"parallel_missions_cap\",\"cap\":{cap},\"active\":{held}}")
      let rawCreateFolder := (bodyVal?.bind (·.fieldStr? "folder")).getD ""
      let .ok validCreateFolder := normalizeMissionFolderStrict rawCreateFolder
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"invalid_folder\"}")
      let normCreateFolder := if projSlug.isEmpty || isBtwReq then "" else validCreateFolder
      let (strippedReqTags, _) := stripLegacyOrbFolderTags reqTags
      let initTagsJson := projectCompatibilityTagsJson authMode placeKind "" "" diskGib strippedReqTags
      let effTrack := if isBtwReq then "" else track
      let nowIso := formatEpochIso8601Utc nowEpochSec
      let mRec : MissionRecord := {
        id := mid, title := title, status := "awaiting_user", backend := backend,
        modelOverride := modelOverride, modelEffort := normEffort, workingDirectory := safeWorkDir,
        project := projSlug, folder := normCreateFolder, createdAt := nowIso, updatedAt := nowIso, totalCostCents := 0,
        authorityMode := authMode, placementKind := placeKind, reservedDiskGib := diskGib,
        nodeBootEpoch := st.store.bootEpoch, tagsJson := initTagsJson, track := effTrack, repo := repo,
        ownerUserId := caller.userId
      }
      match ← insertNewMission st.store mRec with
      | .error "mission_already_exists" =>
        abortIdem
        return .ok (mkJson 409 "{\"error\":\"mission_already_exists\"}")
      | .error e =>
        abortIdem
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () =>
        let mut leaseReservationId := ""
        if !isBtwReq && !projSlug.isEmpty && !effTrack.isEmpty then
          let resId ← nextUniqueId st "rsv" nowEpochSec
          leaseReservationId := resId
          let leaseReq : DispatchLeaseRequest := {
            reservationId := resId, missionId := mid, projectSlug := projSlug,
            track := effTrack, repo := repo, authorityMode := authMode,
            reservedDiskGib := diskGib, bootEpoch := st.store.bootEpoch, nowAt := nowIso
          }
          if let .error leaseErr ← acquireDispatchTrackLease st.store leaseReq then
            discard <| execParamQuery st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
            discard <| recoverDispatchLeases st.store.missionsDb st.store.projectsDb st.store.bootEpoch
            abortIdem
            return .ok (mkJson 409 s!"\{\"error\":{jsonEscape leaseErr}}")
        let mut initStatus := "awaiting_user"
        if !clientPlaced && !isCloudBackendName backend then
          if let (some sup, some targetNode, some rawPrompt) := (st.remoteSup?, remoteNodeId?, prompt?) then
            if !rawPrompt.trimAscii.toString.isEmpty then
              let deliv := if selectedSkills.isEmpty then rawPrompt else withDirective rawPrompt selectedSkills
              discard <| appendMissionEvent st.store mid "user_message"
                (renderCompact (.obj #[("type", .str "user_message"), ("content", .str deliv), ("mission_id", .str mid)])) nowIso
              let spec : RemoteTurnSpec := {
                missionId        := mid
                targetNodeId     := targetNode
                backend          := backend
                modelOverride    := if backend == "opencode" && modelOverride.isEmpty then "builtin/smart" else modelOverride
                modelEffort      := normEffort
                workingDirectory := safeWorkDir
                project          := projSlug
                ownerUserId      := caller.userId
                authorityMode    := authMode
                placementKind    := placeKind
                reservedDiskGib  := diskGib
                tagsJson         := initTagsJson
                prompt           := deliv
                sideQuestion     := isBtwReq
              }
              match ← submitRemoteMissionTurn st.store st.managedStore? st.relayHub? st.broadcastHub? sup st.cfg.workingDir spec nowEpochSec with
              | .ok _ => initStatus := "active"
              | .error dispErr =>
                if !leaseReservationId.isEmpty then
                  discard <| releaseDispatchTrackLease st.store leaseReservationId nowIso
                discard <| execParamQuery st.store.missionsDb "DELETE FROM mission_events WHERE mission_id=?1;" #[mid]
                discard <| execParamQuery st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
                discard <| recoverDispatchLeases st.store.missionsDb st.store.projectsDb st.store.bootEpoch
                abortIdem
                return .ok (mkJson 502 s!"\{\"error\":{jsonEscape dispErr}}")
        let deliveredPromptField :=
          match prompt? with
          | some p =>
            if selectedSkills.isEmpty then ""
            else s!",\"delivered_prompt\":{jsonEscape (withDirective p selectedSkills)}"
          | none => ""
        let projField := if rawProjSlug.isEmpty then "" else s!",\"project\":{jsonEscape rawProjSlug}"
        let rnField := match remoteNodeId? with | some rn => s!",\"remote_node_id\":{jsonEscape rn}" | none => ""
        let respBody :=
          s!"\{\"id\":{jsonEscape mid},\"status\":{jsonEscape initStatus},\"backend\":{jsonEscape backend}," ++
          s!"\"model_override\":{jsonEscape modelOverride},\"model_effort\":{jsonEscape normEffort}," ++
          s!"\"authority_mode\":{jsonEscape authMode},\"placement_kind\":{jsonEscape placeKind}{rnField}," ++
          s!"\"viewer_role\":\"owner\",\"owner_username\":{jsonEscape caller.username}{projField}," ++
          s!"\"folder\":{jsonEscape normCreateFolder},\"placement_revision\":1," ++
          s!"\"created_at\":{jsonEscape nowIso},\"updated_at\":{jsonEscape nowIso}," ++
          s!"\"state_revision\":1,\"total_cost_cents\":0{deliveredPromptField}}"
        let persistInitialCyber : IO Unit := do
          if backend == "codex" && cyberMode != .automatic then
            let rawRev ← newUuidV4
            let rev := (parseUuidCanonical? rawRev).getD rawRev
            let effModel := if modelOverride.isEmpty then defaultCodexModel else modelOverride
            discard <| writeCommitted st.cfg.workingDir mid { mode := cyberMode, revision := rev }
            discard <| writeBinding st.cfg.workingDir mid {
              revision := rev, key := s!"remote-launch:{mid}", model := effModel
            }
        if !idemKey.isEmpty then
          match ← recordOrReplayIdempotency st.store "missions_create" idemKey 201 respBody s!"{nowEpochSec}" with
          | .ok rec =>
            persistInitialCyber
            if let some sIdx := st.searchIdx? then
              discard <| indexConversation sIdx mid title
            return .ok (mkJson rec.statusCode rec.bodyJson)
          | .error e =>
            if !leaseReservationId.isEmpty then
              discard <| releaseDispatchTrackLease st.store leaseReservationId s!"{nowEpochSec}"
            discard <| execParamQuery st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
            discard <| recoverDispatchLeases st.store.missionsDb st.store.projectsDb st.store.bootEpoch
            abortIdem
            return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        persistInitialCyber
        if isCloudBackendName backend then
          if let some cw := st.cloudWakeup? then
            discard <| notifyCloudWorker cw
        let spawnWanted :=
          (bodyJv.fieldBool? "spawn_harness").getD
            (!clientPlaced && remoteNodeId?.isNone && !isCloudBackendName backend)
        if spawnWanted then
          if let some p := prompt? then
            if !p.trimAscii.toString.isEmpty then
              let deliv := if selectedSkills.isEmpty then p else withDirective p selectedSkills
              let permMode := (bodyJv.fieldStr? "permission_mode").getD "supervised"
              let wtMode := (bodyJv.fieldStr? "worktree_mode").getD ""
              discard <| maybeSpawnWarmHarnessTurn st caller placeKind mid backend safeWorkDir deliv modelOverride normEffort permMode wtMode true
        if let some sIdx := st.searchIdx? then
          discard <| indexConversation sIdx mid title
        return .ok (mkJson 201 respBody)

  -- Mission Search (`GET /api/control/missions/search`)
  if req.method == "GET" && cleanPath == "/api/control/missions/search" then
    let qParams := parseQueryParams rawTarget
    let q := (qParams.find? (fun p => p.1 == "q")).map Prod.snd |>.getD ""
    match st.searchIdx? with
    | none => return .ok (mkJson 200 "{\"hits\":[]}")
    | some sIdx =>
      let rawHits ← queryConversations sIdx q 64
      let mut hits : Array String := #[]
      if caller.isLegacyUnscoped then
        hits := rawHits.extract 0 (Nat.min 32 rawHits.size)
      else
        for hMid in rawHits do
          if hits.size < 32 then
            let (ex, isOwn, isPart) ← getMissionRelationship st.store hMid caller.userId
            if ex && (isOwn || isPart) then
              hits := hits.push hMid
      let hitJson := "[" ++ String.intercalate "," (hits.toList.map jsonEscape) ++ "]"
      return .ok (mkJson 200 s!"\{\"hits\":{hitJson}}")

  if let some res ← dispatchMissionControlAndGitRoutes? st req rawTarget cleanPath caller reqOrigin? nowEpochSec then
    return res

  -- Mission Board Task Admission (`POST /api/control/missions/:id/board-task`, `SM-13`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/board-task" rawTarget then
    if req.method == "POST" then
      let rawMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let some mid := percentDecodeStrict rawMid
        | return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      if mid.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let (code, body) ← postBoardTask st.store mid jv
      return .ok (mkJson code body)

  -- Revisioned Mission Move (`POST /api/control/missions/move`, `#1545`)
  if cleanPath == "/api/control/missions/move" then
    if req.method != "POST" then
      return .ok (mkJson 405 "{\"error\":\"method_not_allowed\"}")
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    let missionIds : Array String :=
      match jv.fieldArr? "mission_ids" with
      | some xs => xs.filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      | none =>
        match jv.fieldStr? "mission_id" with
        | some s => let t := s.trimAscii.toString; if t.isEmpty then #[] else #[t]
        | none => #[]
    if missionIds.isEmpty || missionIds.size > 500 then
      return .ok (mkJson 400 "{\"error\":\"mission_ids must contain between 1 and 500 mission IDs\"}")
    let descendantIds : Array String :=
      match jv.fieldArr? "descendant_ids" with
      | some xs => xs.filterMap JVal.asStr? |>.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
      | none => #[]
    let rawProjOpt : Option String :=
      match jv.field? "project" with
      | none | some .null => none
      | some (.str s) =>
        let t := s.trimAscii.toString
        if t.isEmpty || t == "__unassigned__" then none else some t
      | some _ => some "__INVALID__"
    if rawProjOpt == some "__INVALID__" then
      return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
    let rawProjSlug := rawProjOpt.getD ""
    let projSlugRes : Except String String :=
      if rawProjSlug.isEmpty || caller.isLegacyUnscoped then .ok rawProjSlug
      else match scopeProjectSlug caller.userId st.bootstrapAdminId rawProjSlug with
        | some sp => .ok sp
        | none => .error "invalid_project"
    let .ok projSlug := projSlugRes
      | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
    let rawFolderStr :=
      match jv.field? "folder" with
      | none | some .null => ""
      | some (.str s) => s
      | some _ => "\x00"
    let .ok normReqFolder := normalizeMissionFolderStrict rawFolderStr
      | return .ok (mkJson 400 "{\"error\":\"invalid_folder\"}")
    if projSlug.isEmpty && !normReqFolder.isEmpty then
      return .ok (mkJson 400 "{\"error\":\"Folders require a project\"}")
    let policy := ((jv.fieldStr? "approval_policy").getD "check").trimAscii.toString.toLower
    if policy != "check" && policy != "revoke" && policy != "keep" then
      return .ok (mkJson 400 "{\"error\":\"invalid_approval_policy\"}")
    let clientOpIdNum? : Option UInt32 :=
      match jv.fieldNat? "client_op_id" with
      | some n => some n.toUInt32
      | none => ((jv.fieldStr? "client_op_id").bind String.toNat?).map (·.toUInt32)
    let clientId? := (jv.fieldStr? "client_id").map (·.trimAscii.toString) |>.filter (!·.isEmpty)
    let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
    let plan ← match ← planExpandedMoveFamily st.store missionIds descendantIds normReqFolder callerOpt with
      | .ok p => pure p
      | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
    let crossProjIds := (plan.filter (fun m => m.currentProject != projSlug)).map (·.missionId)
    if !crossProjIds.isEmpty && policy == "check" then
      if let some confBody ← inspectCrossProjectSecretTransfer st.store.rootDir crossProjIds rawProjSlug nowEpochSec then
        return .ok (mkJson 409 confBody)
    if !projSlug.isEmpty && !caller.isLegacyUnscoped && !caller.userId.isEmpty then
      discard <| execParamQuery st.store.projectsDb
        "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
        #[projSlug, caller.userId, s!"{nowEpochSec}"]
    let nowIso := formatEpochIso8601Utc nowEpochSec
    let updates : Array CheckedPlacementUpdate := plan.map fun m => {
      missionId       := m.missionId
      expectedProject := m.currentProject
      nextProject     := projSlug
      nextFolder      := m.targetFolder
    }
    let (allMoved, changedMoved) ← match ← batchSetMissionPlacementChecked st.store updates nowIso with
      | .ok pair => pure pair
      | .error (code, msg) => return .ok (mkJson code s!"\{\"error\":{jsonEscape msg}}")
    if !crossProjIds.isEmpty && (policy == "revoke" || policy == "keep") then
      applyCrossProjectSecretPolicy st.store.rootDir crossProjIds rawProjSlug policy nowIso nowEpochSec
    rebindMovedMissionMcpSessions st.store changedMoved
    let unscopeItem (it : MissionPlacementItem) : MissionPlacementItem :=
      if caller.isLegacyUnscoped then it
      else
        let dispProj? := it.project?.map fun p =>
          if p.startsWith (caller.userId ++ ":") then (p.drop (caller.userId.length + 1)).toString else p
        { it with project? := dispProj? }
    let clientAll := allMoved.map unscopeItem
    let clientChanged := changedMoved.map unscopeItem
    let opJson := match clientOpIdNum? with | some n => s!"{n}" | none => "null"
    let cidJson := match clientId? with | some s => jsonEscape s | none => "null"
    if !clientChanged.isEmpty then
      let evPayload := renderMissionPlacementChangedEventJson clientChanged clientOpIdNum? clientId?
      publishControlEvent st.broadcastHub? "mission_placement_changed" evPayload
    let movedJson := "[" ++ String.intercalate "," (clientAll.map renderMissionPlacementItemJson).toList ++ "]"
    return .ok (mkJson 200 s!"\{\"moved\":{movedJson},\"client_op_id\":{opJson},\"client_id\":{cidJson}}")

  -- Mission Resolve (`GET /api/control/missions/resolve`)
  if req.method == "GET" && cleanPath == "/api/control/missions/resolve" then
    let qParams := parseQueryParams rawTarget
    let rawPrefix := ((qParams.find? (fun p => p.1 == "id" || p.1 == "prefix")).bind (fun p => percentDecodeStrict p.2)).getD ""
    let pfx := rawPrefix.trimAscii.toString
    if pfx.isEmpty then
      return .ok (mkJson 400 "{\"error\":\"missing_id\"}")
    let sql :=
      if caller.isLegacyUnscoped then
        "SELECT id FROM missions WHERE id=?1 OR id LIKE (?1 || '%') ORDER BY updated_at DESC LIMIT 2;"
      else
        "SELECT id FROM missions WHERE (id=?1 OR id LIKE (?1 || '%')) AND (owner_user_id=?2 OR EXISTS (SELECT 1 FROM mission_shares s WHERE s.mission_id=missions.id AND s.user_id=?2)) ORDER BY updated_at DESC LIMIT 2;"
    let args := if caller.isLegacyUnscoped then #[pfx] else #[pfx, caller.userId]
    match ← execParamQuery st.store.missionsDb sql args with
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    | .ok rs =>
      if rs.size ≤ 1 then return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let resolvedId := (rs[1]?.bind (·[0]?)).getD ""
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      match ← missionDetailJson st.store resolvedId callerOpt st.bootstrapAdminId with
      | .ok (some body) => return .ok (mkJson 200 body)
      | _ => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")

  -- Mission Control SSE Streams & Sync (`GET /api/control/stream`, `GET /api/control/missions/:id/stream`, `GET /api/control/sync`)
  if req.method == "GET" && cleanPath == "/api/control/stream" then
    let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
    let listBody ← match ← listMissionsJson st.store none callerOpt { limit? := some 200 } with
      | .ok j => pure j
      | .error _ => pure "[]"
    let sseBody := formatSseFrame "missions_snapshot" s!"\{\"missions\":{listBody}}" (some 1)
    return .ok {
      status := 200
      contentType := "text/event-stream"
      corsOrigin? := reqOrigin?
      extraHdrs := #[("Cache-Control", "no-cache")]
      body := sseBody.toUTF8
    }

  if let some params := matchRoutePattern? "/api/control/missions/:id/stream" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let evJson ← match ← queryMissionEventsPage st.store mid none none 100 #[] none with
        | .ok pg => pure pg.eventsJson
        | .error _ => pure "[]"
      let sseBody := formatSseFrame "snapshot" s!"\{\"mission_id\":{jsonEscape mid},\"events\":{evJson}}" (some 1)
      return .ok {
        status := 200
        contentType := "text/event-stream"
        corsOrigin? := reqOrigin?
        extraHdrs := #[("Cache-Control", "no-cache")]
        body := sseBody.toUTF8
      }

  if req.method == "GET" && cleanPath == "/api/control/sync" then
    let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
    let qParams := parseQueryParams rawTarget
    let since? := (qParams.find? (fun p => p.1 == "since" || p.1 == "updated_since")).bind (fun p => percentDecodeStrict p.2)
    let listBody ← match ← listMissionsJson st.store none callerOpt { updatedSince? := since?, limit? := some 500 } with
      | .ok j => pure j
      | .error _ => pure "[]"
    return .ok (mkJson 200 s!"\{\"missions\":{listBody},\"server_time\":{jsonEscape (formatEpochIso8601Utc nowEpochSec)}}")

  -- Mission Settings, Title, Project, Snapshot, Digest & Message Endpoints
  if let some params := (matchRoutePattern? "/api/control/missions/:id/settings" rawTarget).orElse
      (fun _ => (matchRoutePattern? "/api/control/missions/:id/project" rawTarget).orElse
      (fun _ => matchRoutePattern? "/api/control/missions/:id/title" rawTarget)) then
    if req.method == "PATCH" || req.method == "POST" || req.method == "PUT" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      let some existing ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let nextTitle := (jv.fieldStr? "title").getD existing.title
      let nextBackend := (jv.fieldStr? "backend").getD existing.backend
      let nextModel :=
        match jv.field? "model_override" with
        | some .null => ""
        | some (.str s) => s
        | _ => existing.modelOverride
      let nextEffort ← do
        match jv.field? "model_effort" with
        | none => pure existing.modelEffort
        | some .null => pure ""
        | some (.str s) =>
          let t := s.trimAscii.toString
          if t.isEmpty then pure ""
          else match normalizeModelEffortForBackend (some nextBackend) t with
            | some eff => pure eff
            | none => pure "__INVALID__"
        | _ => pure existing.modelEffort
      if nextEffort == "__INVALID__" then
        return .ok (mkJson 400 "{\"error\":\"unsupported_model_effort\"}")
      let hasProjPatch := (jv.field? "project").isSome || (jv.field? "project_slug").isSome
      let nextProj ← do
        if !hasProjPatch then pure existing.project
        else
          let rawP :=
            match (jv.field? "project").orElse (fun _ => jv.field? "project_slug") with
            | some (.str s) => s.trimAscii.toString
            | _ => ""
          if rawP.isEmpty || caller.isLegacyUnscoped then pure rawP
          else pure ((scopeProjectSlug caller.userId st.bootstrapAdminId rawP).getD existing.project)
      let hasFolderPatch := (jv.field? "folder").isSome
      let nextFolder ← do
        if nextProj.isEmpty then pure ""
        else if !hasFolderPatch then
          pure (if nextProj != existing.project then "" else existing.folder)
        else
          match normalizeMissionFolderStrict ((jv.fieldStr? "folder").getD "") with
          | .ok nf => pure nf
          | .error _ => pure "__INVALID_FOLDER__"
      if nextFolder == "__INVALID_FOLDER__" then
        return .ok (mkJson 400 "{\"error\":\"invalid_folder\"}")
      let nowIso := formatEpochIso8601Utc nowEpochSec
      let placementChanged := nextProj != existing.project || nextFolder != existing.folder
      if placementChanged then
        discard <| execParamQuery st.store.missionsDb
          ("UPDATE missions SET title=?2, backend=?3, model_override=?4, model_effort=?5, " ++
           "project=?6, folder=?7, placement_revision=COALESCE(placement_revision,0)+1, " ++
           "metadata_updated_at=?8, state_revision=state_revision+1 WHERE id=?1;")
          #[mid, nextTitle, nextBackend, nextModel, nextEffort, nextProj, nextFolder, nowIso]
      else
        discard <| execParamQuery st.store.missionsDb
          ("UPDATE missions SET title=?2, backend=?3, model_override=?4, model_effort=?5, " ++
           "metadata_updated_at=?6, state_revision=state_revision+1 WHERE id=?1;")
          #[mid, nextTitle, nextBackend, nextModel, nextEffort, nowIso]
      if let some desc := jv.fieldStr? "short_description" then
        discard <| execParamQuery st.store.missionsDb
          "UPDATE missions SET short_description=?2 WHERE id=?1;" #[mid, desc]
      if let some pr := jv.fieldStr? "github_pr" then
        discard <| execParamQuery st.store.missionsDb
          "UPDATE missions SET github_pr=?2, repo=?2 WHERE id=?1;" #[mid, pr]
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      match ← missionDetailJson st.store mid callerOpt st.bootstrapAdminId with
      | .ok (some body) => return .ok (mkJson 200 body)
      | _ => return .ok (mkJson 200 "{\"ok\":true}")

  if let some params := (matchRoutePattern? "/api/control/missions/:id/snapshot" rawTarget).orElse
      (fun _ => matchRoutePattern? "/api/control/missions/:id/digest" rawTarget) then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      let some mBody ← (match ← missionDetailJson st.store mid callerOpt st.bootstrapAdminId with | .ok b => pure b | .error _ => pure none)
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let evJson ← match ← queryMissionEventsPage st.store mid none none 100 #[] none with
        | .ok pg => pure pg.eventsJson
        | .error _ => pure "[]"
      return .ok (mkJson 200 s!"\{\"mission\":{mBody},\"events\":{evJson}}")

  if let some params := (matchRoutePattern? "/api/control/missions/:id/message" rawTarget).orElse
      (fun _ => (matchRoutePattern? "/api/control/missions/:id/adopt" rawTarget).orElse
      (fun _ => matchRoutePattern? "/api/control/missions/:id/acknowledge" rawTarget)) then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let some mRec ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let nowIso := formatEpochIso8601Utc nowEpochSec
      if cleanPath.endsWith "/acknowledge" then
        discard <| mark_mission_opened st.store mid nowIso
        return .ok (mkJson 200 "{\"ok\":true}")
      let content := ((jv.fieldStr? "content").orElse (fun _ => jv.fieldStr? "message")).getD ""
      let mut queued := false
      if !content.trimAscii.toString.isEmpty then
        let defMsgId ← nextUniqueId st "msg" nowEpochSec
        let msgId := (jv.fieldStr? "client_message_id").getD defMsgId
        let pl := renderCompact (.obj #[
          ("type", .str "user_message"),
          ("id", .str msgId),
          ("content", .str content),
          ("mission_id", .str mid),
          ("sender_user_id", .str caller.userId),
          ("sender_username", .str caller.username)
        ])
        match st.remoteSup?, (← resolveMissionRemoteNode? st.store st.managedStore? mid) with
        | some sup, some targetNode =>
          if mRec.status == "active" || mRec.status == "pending" then
            discard <| enqueueStructuredFollowup st.store "core" msgId mid content "control" nowIso
            queued := true
          else
            discard <| appendMissionEvent st.store mid "user_message" pl nowIso
            let mut resumeSid? : Option String := none
            if let .ok sRows ← execParamQuery st.store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
              if sRows.size > 1 then
                let s := (cell sRows[1]! 0).trimAscii.toString
                if !s.isEmpty then resumeSid? := some s
            let isSide := (OrbBin.Json.parse mRec.tagsJson).toOption.bind JVal.asArr? |>.getD #[] |>.any (fun v => v.asStr? == some "side-question")
            let spec : RemoteTurnSpec := {
              missionId        := mid
              targetNodeId     := targetNode
              backend          := mRec.backend
              modelOverride    := if mRec.backend == "opencode" && mRec.modelOverride.isEmpty then "builtin/smart" else mRec.modelOverride
              modelEffort      := mRec.modelEffort
              workingDirectory := mRec.workingDirectory
              project          := mRec.project
              ownerUserId      := mRec.ownerUserId
              authorityMode    := mRec.authorityMode
              placementKind    := mRec.placementKind
              reservedDiskGib  := mRec.reservedDiskGib
              tagsJson         := mRec.tagsJson
              prompt           := content
              resumeSessionId? := resumeSid?
              sideQuestion     := isSide
            }
            if let .error dispErr ← submitRemoteMissionTurn st.store st.managedStore? st.relayHub? st.broadcastHub? sup st.cfg.workingDir spec nowEpochSec then
              return .ok (mkJson 502 s!"\{\"error\":{jsonEscape dispErr}}")
        | _, _ =>
          discard <| appendMissionEvent st.store mid "user_message" pl nowIso
          discard <| maybeSpawnWarmHarnessTurn
            st caller mRec.placementKind mid mRec.backend mRec.workingDirectory
            content mRec.modelOverride mRec.modelEffort "supervised" "" false
      else if cleanPath.endsWith "/adopt" then
        discard <| execParamQuery st.store.missionsDb
          "UPDATE missions SET status='awaiting_user', orphaned_at='', state_revision=state_revision+1, updated_at=?2 WHERE id=?1;"
          #[mid, nowIso]
      return .ok (mkJson 200 s!"\{\"ok\":true,\"queued\":{if queued then "true" else "false"},\"mission_id\":{jsonEscape mid},\"sender_user_id\":{jsonEscape caller.userId},\"sender_username\":{jsonEscape caller.username}}")

  -- Cloud Agent & Parity Sub-Routes before `/api/control/missions/:id`
  if cleanPath.startsWith "/api/cloud/" ||
     (cleanPath.startsWith "/api/control/missions/" && (
       (cleanPath.splitOn "/cloud").length > 1 ||
       cleanPath.endsWith "/inbox-digest" ||
       cleanPath.endsWith "/stats" ||
       cleanPath.endsWith "/messages/context" ||
       cleanPath.endsWith "/client-run" ||
       cleanPath.endsWith "/client-status" ||
       cleanPath.endsWith "/client-transcript" ||
       cleanPath.startsWith "/api/control/missions/search/")) then
    let cHub ← match st.cloudHub? with | some h => pure h | none => newCloudRuntimeHub
    if let some (cCode, cCtype, cBody) ← dispatchCloudHttpRoute
        cHub st.store st.broadcastHub? st.cfg.port
        req.method cleanPath rawTarget req.bodySlice.toByteArray
        caller.userId caller.username st.bootstrapAdminId
        (caller.isLegacyUnscoped || caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := cCode, contentType := cCtype, corsOrigin? := reqOrigin?, body := cBody }
    let sHub ← match st.systemHub? with | some h => pure h | none => newSystemRuntimeHub
    if let some (sCode, sCtype, sBody) ← dispatchResourcesAndSystemRoute
        sHub st.store st.cfg.workingDir st.cfg.libraryRemote st.cfg.githubClientId
        st.bunkerStateRef? st.managedStore? st.relayHub? st.broadcastHub?
        req.method cleanPath rawTarget req.headers req.bodySlice.toByteArray
        caller.userId caller.username st.bootstrapAdminId
        (caller.isLegacyUnscoped || caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := sCode, contentType := sCtype, corsOrigin? := reqOrigin?, body := sBody }

  -- Mission Detail & Delete (`GET|DELETE /api/control/missions/:id`, `SM-01`, `SM-07`)
  if let some params := matchRoutePattern? "/api/control/missions/:id" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if req.method == "GET" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let callerOpt := if caller.isLegacyUnscoped then none else some caller.userId
      match ← missionDetailJson st.store mid callerOpt st.bootstrapAdminId with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok none => return .ok (mkJson 404 "{\"error\":\"mission_not_found\"}")
      | .ok (some body) => return .ok (mkJson 200 body)
    else if req.method == "DELETE" then
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid true) then
        return .ok (mkJson cCode cBody)
      revokeMissionProxyTokensForMission st.store mid
      let delRes ← withImmediateTx st.store.missionsDb do
        discard <| execParamQueryUnlocked st.store.missionsDb "DELETE FROM mission_shares WHERE mission_id=?1;" #[mid]
        discard <| execParamQueryUnlocked st.store.missionsDb "DELETE FROM mission_events WHERE mission_id=?1;" #[mid]
        discard <| execParamQueryUnlocked st.store.missionsDb "DELETE FROM mission_runs WHERE mission_id=?1;" #[mid]
        discard <| execParamQueryUnlocked st.store.missionsDb "DELETE FROM mission_continuations WHERE mission_id=?1;" #[mid]
        execParamQueryUnlocked st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
      match delRes with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ => return .ok (mkJson 200 "{\"ok\":true}")

  -- Project Decisions (`GET|POST /api/control/projects/:slug/decisions`, `SM-13`)
  if let some params := matchRoutePattern? "/api/control/projects/:slug/decisions" rawTarget then
    let rawSlug := (params.find? (fun p => p.1 == "slug")).map Prod.snd |>.getD ""
    let some decSlug := percentDecodeStrict rawSlug
      | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
    let slugOpt : Option String :=
      if caller.isLegacyUnscoped then
        if validProjectSlug decSlug then some decSlug else none
      else
        scopeProjectSlug caller.userId st.bootstrapAdminId decSlug
    let some slug := slugOpt
      | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
    if req.method == "GET" then
      match ← listProjectDecisionsJson st.store slug with
      | .ok body => return .ok (mkJson 200 body)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" || req.method == "PUT" || req.method == "PATCH" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      if !caller.isLegacyUnscoped && !caller.userId.isEmpty then
        discard <| execParamQuery st.store.projectsDb
          "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
          #[slug, caller.userId, s!"{nowEpochSec}"]
      let defDid ← nextUniqueId st "dec" nowEpochSec
      let did := (jv.fieldStr? "id").getD defDid
      let status := (jv.fieldStr? "status").getD "pending"
      let question := (jv.fieldStr? "question").getD ""
      let evidence := (jv.fieldStr? "evidence").getD ""
      let answered? := jv.fieldBool? "answered"
      let drec : ProjectDecision := {
        id := did, projectSlug := slug, status := status,
        question := question, evidence := evidence, updatedAt := s!"{nowEpochSec}"
      }
      match ← putProjectDecision st.store drec answered? with
      | .ok out =>
        let ansStr := if answeredOfStatus out.status then "true" else "false"
        let dispProj := if caller.isLegacyUnscoped then out.projectSlug else decSlug
        return .ok (mkJson 200 s!"\{\"id\":{jsonEscape out.id},\"project_slug\":{jsonEscape dispProj},\"status\":{jsonEscape out.status},\"answered\":{ansStr}}")
      | .error "invalid_decision_status" | .error "contradictory_answered" =>
        return .ok (mkJson 400 "{\"error\":\"invalid_or_contradictory_decision_status\"}")
      | .error e =>
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- AI Providers CRUD, Usage, CLIProxy Login, Summary & Rate-Limit Metadata (`/api/ai/providers*`, `/api/ai/usage/*`, `/api/ai/proxy/*`)
  if cleanPath.startsWith "/api/ai/usage/" || cleanPath.startsWith "/api/ai/proxy/" then
    let pHub ← match st.providerHub? with | some h => pure h | none => newProviderRuntimeHub
    if let some (pCode, pCtype, pBody) ← dispatchProviderAndAiRoute
        pHub st.store st.cfg.workingDir st.cfg.port st.pacingTracker? st.proxyCooldownsRef
        req.method cleanPath rawTarget req.bodySlice.toByteArray
        caller.userId (caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := pCode, contentType := pCtype, corsOrigin? := reqOrigin?, body := pBody }

  if cleanPath == "/api/ai/providers" || cleanPath.startsWith "/api/ai/providers/" then
    if let some params := matchRoutePattern? "/api/ai/providers/:id/preference" rawTarget then
      if req.method == "PUT" || req.method == "PATCH" then
        let pid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
        let some existing ← getAIProvider? st.store pid
          | return .ok (mkJson 404 "{\"error\":\"provider_not_found\"}")
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let some userEn := jv.fieldBool? "enabled"
          | return .ok (mkJson 400 "{\"error\":\"missing_enabled_boolean\"}")
        let prefUid := if caller.userId.isEmpty then "admin" else caller.userId
        match ← setUserProviderPref st.store prefUid pid userEn s!"{nowEpochSec}" with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok () =>
          let obs? ← match st.pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr existing.id
            | none => pure none
          return .ok (mkJson 200 (renderAIProviderForCallerJson existing (caller.role == "admin") userEn obs?))
    -- Delegate rich GET list/detail, `/usage`, `/types`, `/reorder`, `/for-backend/*`, `/cli-proxy-login*`, `/:id/{usage,default,health,reset-usage,antigravity/recheck,auth/methods}` BEFORE `:id` PUT/DELETE
    let pHub ← match st.providerHub? with | some h => pure h | none => newProviderRuntimeHub
    if let some (pCode, pCtype, pBody) ← dispatchProviderAndAiRoute
        pHub st.store st.cfg.workingDir st.cfg.port st.pacingTracker? st.proxyCooldownsRef
        req.method cleanPath rawTarget req.bodySlice.toByteArray
        caller.userId (caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := pCode, contentType := pCtype, corsOrigin? := reqOrigin?, body := pBody }
    if req.method == "GET" && cleanPath == "/api/ai/providers" then
      let providers ← listAIProviders st.store
      if caller.isLegacyUnscoped then
        let mut items : Array String := Array.mkEmpty providers.size
        for p in providers do
          let obs? ← match st.pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr p.id
            | none => pure none
          items := items.push (renderAIProviderJson p obs?)
        return .ok (mkJson 200 ("[" ++ String.intercalate "," items.toList ++ "]"))
      else
        let isAdm := caller.role == "admin"
        let uPrefs ← getUserProviderPrefs st.store caller.userId
        let mut items : Array String := Array.mkEmpty providers.size
        for p in providers do
          if isAdm || (!p.apiKey.isEmpty && p.enabled) then
            let obs? ← match st.pacingTracker? with
              | some tr => lookupObservedKeyRpm? tr p.id
              | none => pure none
            let uEn := isUserProviderEnabled uPrefs p.id
            items := items.push (renderAIProviderForCallerJson p isAdm uEn obs?)
        return .ok (mkJson 200 ("[" ++ String.intercalate "," items.toList ++ "]"))
    else if req.method == "POST" && cleanPath == "/api/ai/providers" then
      if !caller.isLegacyUnscoped then
        if let some (cCode, cBody) := requireAdminPrincipal caller then
          return .ok (mkJson cCode cBody)
      let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
      let .ok jv := OrbBin.Json.parse rawBody
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let defPid ← nextUniqueId st "prov" nowEpochSec
      let pid := ((jv.fieldStr? "id").getD defPid).trimAscii.toString
      let pType := ((jv.fieldStr? "provider_type").getD "custom").trimAscii.toString
      let nm := ((jv.fieldStr? "name").getD pType).trimAscii.toString
      let enabled := (jv.fieldBool? "enabled").getD true
      let baseUrl := ((jv.fieldStr? "base_url").getD "").trimAscii.toString
      let apiKey := ((jv.fieldStr? "api_key").getD "").trimAscii.toString
      let .ok rpm? := parseOptionalBoundedU32 jv "rpm_limit" 1 100000
        | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"rpm_limit\"}")
      let .ok conc? := parseOptionalBoundedU32 jv "max_concurrency" 1 1024
        | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"max_concurrency\"}")
      let customModelsRes : Except String (Array CustomModelConfig) :=
        match jv.field? "custom_models" with
        | none | some .null => .ok #[]
        | some (.arr arr) => parseCustomModelsStrict arr
        | some _ => .error "custom_models_must_be_array"
      let .ok cModels := customModelsRes
        | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"custom_models\"}")
      let provRec : AIProviderRecord := {
        id := pid, providerType := pType, name := nm, enabled := enabled,
        baseUrl := baseUrl, apiKey := apiKey, rpmLimit? := rpm?, maxConcurrency? := conc?,
        customModels := cModels, updatedAt := s!"{nowEpochSec}"
      }
      match ← upsertAIProvider st.store provRec with
      | .error e => return .ok (mkJson 400 s!"\{\"error\":\"invalid_provider_limits\",\"detail\":{jsonEscape e}}")
      | .ok () =>
        let refreshed ← loadRoutingChainsFromStore st.store st.cfg.workingDir
        discard <| publishRoutingChainsUpdate st refreshed
        return .ok (mkJson 201 (renderAIProviderJson provRec none))
    else if let some params := matchRoutePattern? "/api/ai/providers/:id" rawTarget then
      if !caller.isLegacyUnscoped then
        if let some (cCode, cBody) := requireAdminPrincipal caller then
          return .ok (mkJson cCode cBody)
      let pid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if req.method == "PUT" || req.method == "PATCH" then
        let some existing ← getAIProvider? st.store pid
          | return .ok (mkJson 404 "{\"error\":\"provider_not_found\"}")
        let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
        let .ok jv := OrbBin.Json.parse rawBody
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let nm := match jv.fieldStr? "name" with
          | some s => let t := s.trimAscii.toString; if t.isEmpty then existing.name else t
          | none => existing.name
        let enabled := (jv.fieldBool? "enabled").getD existing.enabled
        let baseUrl := match jv.field? "base_url" with
          | none => existing.baseUrl
          | some .null => ""
          | some (.str s) => s.trimAscii.toString
          | some _ => existing.baseUrl
        let apiKey := match jv.fieldStr? "api_key" with
          | some s => let t := s.trimAscii.toString; if t.isEmpty then existing.apiKey else t
          | none => existing.apiKey
        let rpmRes : Except String (Option UInt32) :=
          match jv.field? "rpm_limit" with
          | none => .ok existing.rpmLimit?
          | some .null => .ok none
          | some _ => parseOptionalBoundedU32 jv "rpm_limit" 1 100000
        let .ok rpm? := rpmRes
          | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"rpm_limit\"}")
        let concRes : Except String (Option UInt32) :=
          match jv.field? "max_concurrency" with
          | none => .ok existing.maxConcurrency?
          | some .null => .ok none
          | some _ => parseOptionalBoundedU32 jv "max_concurrency" 1 1024
        let .ok conc? := concRes
          | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"max_concurrency\"}")
        let modelsRes : Except String (Array CustomModelConfig) :=
          match jv.field? "custom_models" with
          | none => .ok existing.customModels
          | some .null => .ok #[]
          | some (.arr arr) => parseCustomModelsStrict arr
          | some _ => .error "custom_models_must_be_array"
        let .ok cModels := modelsRes
          | return .ok (mkJson 400 "{\"error\":\"invalid_provider_limits\",\"field\":\"custom_models\"}")
        let updated : AIProviderRecord := {
          existing with
          name := nm, enabled := enabled, baseUrl := baseUrl, apiKey := apiKey,
          rpmLimit? := rpm?, maxConcurrency? := conc?, customModels := cModels,
          updatedAt := s!"{nowEpochSec}"
        }
        match ← upsertAIProvider st.store updated with
        | .error e => return .ok (mkJson 400 s!"\{\"error\":\"invalid_provider_limits\",\"detail\":{jsonEscape e}}")
        | .ok () =>
          let refreshed ← loadRoutingChainsFromStore st.store st.cfg.workingDir
          discard <| publishRoutingChainsUpdate st refreshed
          let obs? ← match st.pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr updated.id
            | none => pure none
          return .ok (mkJson 200 (renderAIProviderJson updated obs?))
      else if req.method == "DELETE" then
        match ← deleteAIProvider st.store pid with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok () =>
          let refreshed ← loadRoutingChainsFromStore st.store st.cfg.workingDir
          discard <| publishRoutingChainsUpdate st refreshed
          return .ok (mkJson 200 "{\"ok\":true}")

  -- Harness Backends & Curated Provider Model Catalog (`/api/backends`, `/api/providers`, `/api/providers/backend-models`, `/api/providers/antigravity-models`)
  if req.method == "GET" && cleanPath == "/api/backends" then
    let backendsJson :=
      "[" ++
      "{\"id\":\"claudecode\",\"name\":\"Claude Code\",\"native_plan\":true}," ++
      "{\"id\":\"codex\",\"name\":\"Codex\",\"native_plan\":true}," ++
      "{\"id\":\"grok\",\"name\":\"Grok\",\"native_plan\":false}," ++
      "{\"id\":\"opencode\",\"name\":\"OpenCode\",\"native_plan\":false}," ++
      "{\"id\":\"antigravity\",\"name\":\"Antigravity CLI\",\"native_plan\":true}," ++
      "{\"id\":\"vibe\",\"name\":\"Mistral Vibe\",\"native_plan\":false}" ++
      "]"
    return .ok (mkJson 200 backendsJson)

  if req.method == "GET" && cleanPath == "/api/providers" then
    return .ok (mkJson 200 (← renderProviderCatalogJson st.store caller))

  if cleanPath.startsWith "/api/providers/" || cleanPath == "/api/antigravity-models" then
    if cleanPath != "/api/providers/backend-models" then
      let pHub ← match st.providerHub? with | some h => pure h | none => newProviderRuntimeHub
      if let some (pCode, pCtype, pBody) ← dispatchProviderAndAiRoute
          pHub st.store st.cfg.workingDir st.cfg.port st.pacingTracker? st.proxyCooldownsRef
          req.method cleanPath rawTarget req.bodySlice.toByteArray
          caller.userId (caller.role == "admin") caller.isLegacyUnscoped then
        return .ok { status := pCode, contentType := pCtype, corsOrigin? := reqOrigin?, body := pBody }

  if req.method == "GET" && cleanPath == "/api/providers/backend-models" then
    let isAdm := caller.isLegacyUnscoped || caller.role == "admin"
    let uPrefs ← if caller.isLegacyUnscoped then pure #[] else getUserProviderPrefs st.store caller.userId
    let mkOpt (val lbl desc : String) : String :=
      if desc.isEmpty then
        s!"\{\"value\":{jsonEscape val},\"label\":{jsonEscape lbl}}"
      else
        s!"\{\"value\":{jsonEscape val},\"label\":{jsonEscape lbl},\"description\":{jsonEscape desc}}"
    let claudeModels : Array String := #[
      mkOpt "claude-opus-5-5" "Claude (Subscription) — Claude Opus 5.5" "Default for complex agentic coding, always-adaptive thinking, 1M context",
      mkOpt "claude-opus-5" "Claude (Subscription) — Claude Opus 5" "Complex agentic coding, adaptive thinking, 1M context",
      mkOpt "claude-fable-5-2" "Claude (Subscription) — Claude Fable 5.2" "Demanding reasoning and long-horizon agentic work, adaptive thinking (efforts low..max), 1M context",
      mkOpt "claude-mythos-5-2" "Claude (Subscription) — Claude Mythos 5.2" "Mythos-class reasoning and cyber/life-sciences research (requires verified organization access), 1M context",
      mkOpt "claude-sonnet-5-5" "Claude (Subscription) — Claude Sonnet 5.5" "Latest Sonnet, efficient for routine tasks",
      mkOpt "claude-sonnet-4-6" "Claude (Subscription) — Claude Sonnet 4.6" "Balanced speed and capability",
      mkOpt "claude-haiku-5-5" "Claude (Subscription) — Claude Haiku 5.5" "Latest Haiku, fastest for quick answers"
    ]
    let codexModels : Array String := #[
      mkOpt "gpt-6.1-sol" "OpenAI (Subscription) — GPT-6.1 Sol" "Newest Codex flagship (efforts low..ultra). Default.",
      mkOpt "gpt-6.1-terra" "OpenAI (Subscription) — GPT-6.1 Terra" "GPT-6.1 model with lower cost than Sol (efforts low..ultra).",
      mkOpt "gpt-6-astra" "OpenAI (Subscription) — GPT-6 Astra" "OpenAI's GPT-6 flagship in Codex (efforts low..ultra).",
      mkOpt "gpt-6-sol" "OpenAI (Subscription) — GPT-6 Sol" "GPT-6 model for complex reasoning and coding (efforts low..ultra).",
      mkOpt "gpt-6-luna" "OpenAI (Subscription) — GPT-6 Luna" "GPT-6 model optimized for speed and cost (efforts low..max).",
      mkOpt "gpt-5.6" "OpenAI (Subscription) — GPT-5.6" "Flagship GPT-5.6 reasoning and coding model",
      mkOpt "gpt-5.5-codex" "OpenAI (Subscription) — GPT-5.5 Codex" "Codex-optimized coding model"
    ]
    let grokModels : Array String := #[
      mkOpt "grok-4.7" "xAI — Grok 4.7" "Latest flagship Grok model",
      mkOpt "grok-4.7-build-fast" "xAI — Grok 4.7 Build (Fast)" "Faster Grok 4.7 variant for coding agents",
      mkOpt "grok-4.6" "xAI — Grok 4.6" "Previous flagship Grok model",
      mkOpt "grok-build-latest" "xAI — Grok Build (Latest)" "Rolling Grok Build alias"
    ]
    let mut opencodeModels : Array String := #[
      mkOpt "anthropic/claude-opus-5-5" "Anthropic — Claude Opus 5.5" "",
      mkOpt "anthropic/claude-opus-5" "Anthropic — Claude Opus 5" "",
      mkOpt "anthropic/claude-fable-5-2" "Anthropic — Claude Fable 5.2" "",
      mkOpt "anthropic/claude-mythos-5-2" "Anthropic — Claude Mythos 5.2" "",
      mkOpt "anthropic/claude-sonnet-5-5" "Anthropic — Claude Sonnet 5.5" "",
      mkOpt "anthropic/claude-sonnet-4-6" "Anthropic — Claude Sonnet 4.6" "",
      mkOpt "openai/gpt-6.1-sol" "OpenAI — GPT-6.1 Sol" "",
      mkOpt "openai/gpt-6-astra" "OpenAI — GPT-6 Astra" "",
      mkOpt "xai/grok-4.7" "xAI — Grok 4.7" "",
      mkOpt "muse/muse-wonder-1.0" "Meta Muse — Muse Wonder 1.0" "",
      mkOpt "muse/muse-ember-1.0" "Meta Muse — Muse Ember 1.0" "",
      mkOpt "muse/muse-spark-1.3-contributor" "Meta Muse — Muse Spark 1.3 Contributor" "",
      mkOpt "muse/muse-spark-1.3" "Meta Muse — Muse Spark 1.3" ""
    ]
    let dbProviders ← listAIProviders st.store
    for p in dbProviders do
      let effEn := if caller.isLegacyUnscoped then p.enabled else (p.enabled && (isAdm || !p.apiKey.isEmpty) && isUserProviderEnabled uPrefs p.id)
      if effEn then
        for cm in p.customModels do
          let mid := cm.id.trimAscii.toString
          if !mid.isEmpty then
            let rawLbl := (cm.name?.getD "").trimAscii.toString
            let mlbl := if rawLbl.isEmpty then mid else rawLbl
            opencodeModels := opencodeModels.push (mkOpt s!"{p.id}/{mid}" s!"{p.name} — {mlbl}" "")
    let mut agyModels : Array String := #[]
    if isAdm then
      let pHub ← match st.providerHub? with | some h => pure h | none => newProviderRuntimeHub
      let pairs ← getCachedAntigravityModels pHub false
      for (mId, mLbl) in pairs do
        agyModels := agyModels.push (mkOpt mId mLbl "")
    let vibeModels : Array String := #[
      mkOpt "mistral/mistral-vibe-cli-latest" "Mistral Vibe" "Native Mistral Vibe CLI"
    ]
    let renderArr (xs : Array String) : String := "[" ++ String.intercalate "," xs.toList ++ "]"
    let payload :=
      "{\"backends\":{" ++
      s!"\"claudecode\":{renderArr claudeModels}," ++
      s!"\"codex\":{renderArr codexModels}," ++
      s!"\"grok\":{renderArr grokModels}," ++
      s!"\"opencode\":{renderArr opencodeModels}," ++
      s!"\"antigravity\":{renderArr agyModels}," ++
      s!"\"vibe\":{renderArr vibeModels}" ++
      "}}"
    return .ok (mkJson 200 payload)

  -- Model Routing Controls (`"/api/model-routing"` / `/api/model-routing/chains`)
  if cleanPath.startsWith "/api/model-routing" then
    let pHub ← match st.providerHub? with | some h => pure h | none => newProviderRuntimeHub
    if let some (mCode, mCtype, mBody) ← dispatchProviderAndAiRoute
        pHub st.store st.cfg.workingDir st.cfg.port st.pacingTracker? st.proxyCooldownsRef
        req.method cleanPath rawTarget req.bodySlice.toByteArray
        caller.userId (caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := mCode, contentType := mCtype, corsOrigin? := reqOrigin?, body := mBody }
    if req.method != "GET" && !caller.isLegacyUnscoped then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
    if let some params := matchRoutePattern? "/api/model-routing/chains/:id/resolve" rawTarget then
      if req.method == "GET" then
        if !caller.isLegacyUnscoped then
          if let some (cCode, cBody) := requireAdminPrincipal caller then
            return .ok (mkJson cCode cBody)
        let cid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
        let chains ← loadRoutingChainsFromStore st.store st.cfg.workingDir
        discard <| publishRoutingChainsUpdate st chains (forceBump := false)
        match chains.find? (fun c => c.id == cid) with
        | none => return .ok (mkJson 404 "{\"error\":\"chain_not_found\"}")
        | some ch =>
          let resolvedJson ← renderResolvedChainJson ch st.pacingTracker?
          return .ok (mkJson 200 resolvedJson)
    -- Chain CRUD in the Rust `ChainResponse` shape. One loader serves list, get,
    -- create and update, so the clients' `ModelChain` type has a single producer.
    let isoOf := fun (raw : String) =>
      let t := raw.trimAscii.toString
      if t.isEmpty then formatEpochIso8601Utc nowEpochSec
      else match t.toNat? with
        | some n => formatEpochIso8601Utc n.toUInt64
        | none => t
    let loadChainRows : IO (Array JVal) := do
      let .ok rs ← execParamQuery st.store.missionsDb
          "SELECT id,name,models_json,COALESCE(updated_at,''),COALESCE(created_at,''),COALESCE(is_default,-1),COALESCE(strip_thinking,-1) FROM model_routing_chains ORDER BY id ASC;" #[]
        | throw (IO.userError "routing_chain_store_unavailable")
      let rows := rs.extract 1 rs.size
      let explicitDefault := rows.any (fun r => r[5]? == some "1")
      let mut out : Array JVal := #[]
      for r in rows do
        let cid := (r[0]?).getD ""
        let updated := isoOf ((r[3]?).getD "")
        let created := if ((r[4]?).getD "").isEmpty then updated else isoOf ((r[4]?).getD "")
        let isDef := if explicitDefault then r[5]? == some "1" else cid == "builtin/smart"
        let strip := if r[6]? == some "-1" then cid == "builtin/assistant" else r[6]? == some "1"
        out := out.push (OrbCore.ProxyModelRouting.chainResponse cid ((r[1]?).getD cid) ((r[2]?).getD "[]") isDef strip created updated)
      -- Stock chains the proxy serves are listed even before anyone edits them.
      for (sid, sname, entries) in OrbCore.ProxyModelRouting.stockChains do
        if !out.any (fun c => c.fieldStr? "id" == some sid) then
          let now := formatEpochIso8601Utc nowEpochSec
          out := out.push (OrbCore.ProxyModelRouting.chainResponse sid sname
            (OrbCore.ProxyModelRouting.entriesJson entries) (!explicitDefault && sid == "builtin/smart") (sid == "builtin/assistant") now now)
      return out
    let chainId? := (matchRoutePattern? "/api/model-routing/chains/:id" rawTarget).bind fun ps =>
      (ps.find? (fun p => p.1 == "id")).map Prod.snd
    if req.method == "GET" && cleanPath == "/api/model-routing/chains" then
      return .ok (mkJson 200 (renderCompact (.arr (← loadChainRows))))
    else if req.method == "GET" && chainId?.isSome then
      match (← loadChainRows).find? (fun c => c.fieldStr? "id" == chainId?) with
      | some c => return .ok (mkJson 200 (renderCompact c))
      | none => return .ok (mkJson 404 "{\"error\":\"chain_not_found\"}")
    else if req.method == "DELETE" && chainId?.isSome then
      let cid := chainId?.getD ""
      if cid.startsWith "builtin/" then
        return .ok (mkJson 400 "{\"error\":\"builtin_chain_cannot_be_deleted\"}")
      let .ok found ← execParamQuery st.store.missionsDb "SELECT 1 FROM model_routing_chains WHERE id=?1;" #[cid]
        | return .ok (mkJson 500 "{\"error\":\"routing_chain_store_unavailable\"}")
      if found.size ≤ 1 then return .ok (mkJson 404 "{\"error\":\"chain_not_found\"}")
      discard <| execParamQuery st.store.missionsDb "DELETE FROM model_routing_chains WHERE id=?1;" #[cid]
      discard <| publishRoutingChainsUpdate st (← loadRoutingChainsFromStore st.store st.cfg.workingDir)
      return .ok (mkJson 200 "{\"ok\":true}")
    else if (req.method == "POST" && cleanPath == "/api/model-routing/chains") ||
            (req.method == "PUT" && chainId?.isSome) then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let defCid ← nextUniqueId st "chain" nowEpochSec
      let cid := chainId?.orElse (fun _ => jv.fieldStr? "id") |>.getD defCid
      let existing? := (← loadChainRows).find? (fun c => c.fieldStr? "id" == some cid)
      let .ok storedRows ← execParamQuery st.store.missionsDb "SELECT models_json FROM model_routing_chains WHERE id=?1;" #[cid]
        | return .ok (mkJson 500 "{\"error\":\"routing_chain_store_unavailable\"}")
      -- A partial update keeps every field it does not name (the desktop's
      -- "set default" sends only `is_default`).
      let modelsJson? := match (jv.field? "entries").orElse (fun _ => jv.field? "models") with
        | some arr@(.arr _) => some (OrbCore.ProxyModelRouting.keepStoredEntrySettings (renderCompact arr)
            ((storedRows[1]?.bind (·[0]?)).getD "[]"))
        | _ => (jv.fieldStr? "models_json").orElse fun _ =>
            (storedRows[1]?.bind (·[0]?)).orElse fun _ =>
              existing?.map (fun (c : JVal) => renderCompact (c.fieldOrNull "entries"))
      let some modelsJson := modelsJson?
        | return .ok (mkJson 400 "{\"error\":\"entries_required\"}")
      if modelsJson == "[]" then return .ok (mkJson 400 "{\"error\":\"entries_required\"}")
      let nm := (jv.fieldStr? "name").orElse (fun _ => existing?.bind (·.fieldStr? "name")) |>.getD cid
      let strip := (jv.fieldBool? "strip_thinking").orElse (fun _ => existing?.bind (·.fieldBool? "strip_thinking")) |>.getD false
      let nowIso := formatEpochIso8601Utc nowEpochSec
      let created := (existing?.bind (·.fieldStr? "created_at")).getD nowIso
      if jv.fieldBool? "is_default" == some true then
        -- Materialise the current flags first so exactly one chain is the default.
        for c in (← loadChainRows) do
          discard <| execParamQuery st.store.missionsDb "UPDATE model_routing_chains SET is_default=0 WHERE id=?1;" #[(c.fieldStr? "id").getD ""]
      let isDefSql := match jv.fieldBool? "is_default" with
        | some true => "1" | some false => "0"
        | none => if (existing?.bind (·.fieldBool? "is_default")).getD false then "1" else "0"
      match ← execParamQuery st.store.missionsDb
        ("INSERT INTO model_routing_chains(id,name,models_json,updated_at,created_at,is_default,strip_thinking) VALUES(?1,?2,?3,?4,?5,CAST(?6 AS INTEGER),CAST(?7 AS INTEGER)) " ++
         "ON CONFLICT(id) DO UPDATE SET name=excluded.name,models_json=excluded.models_json,updated_at=excluded.updated_at,created_at=excluded.created_at,is_default=excluded.is_default,strip_thinking=excluded.strip_thinking;")
        #[cid, nm, modelsJson, nowIso, created, isDefSql, if strip then "1" else "0"] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        discard <| publishRoutingChainsUpdate st (← loadRoutingChainsFromStore st.store st.cfg.workingDir)
        let saved := ((← loadChainRows).find? (fun (c : JVal) => c.fieldStr? "id" == some cid)).getD .null
        return .ok (mkJson (if req.method == "POST" then 201 else 200) (renderCompact saved))
    else
      return .ok (mkJson 404 "{\"error\":\"not_found\"}")

  -- Managed Compute Fleet (`/api/managed-machines*`, `/api/remote-nodes`)
  if let some params := matchRoutePattern? "/api/managed-machines/providers/:provider/preference" rawTarget then
    if req.method == "PUT" || req.method == "PATCH" then
      let prov := canonicalizeProvider ((params.find? (fun p => p.1 == "provider")).map Prod.snd |>.getD "")
      if !isKnownProvider prov then
        return .ok (mkJson 400 "{\"error\":\"unknown_provider\"}")
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let some en := jv.fieldBool? "enabled"
        | return .ok (mkJson 400 "{\"error\":\"missing_enabled_boolean\"}")
      let prefUid := if caller.userId.isEmpty then "admin" else caller.userId
      match ← setUserManagedPref mst prefUid prov en s!"{nowEpochSec}" with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"provider\":{jsonEscape prov},\"user_enabled\":{if en then "true" else "false"}}")

  if let some params := matchRoutePattern? "/api/managed-machines/providers/:provider" rawTarget then
    if req.method == "PUT" || req.method == "PATCH" || req.method == "DELETE" then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
      let prov := canonicalizeProvider ((params.find? (fun p => p.1 == "provider")).map Prod.snd |>.getD "")
      if !isKnownProvider prov then
        return .ok (mkJson 400 "{\"error\":\"unknown_provider\"}")
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let cachedFleet ← st.managedRef.get
      let .ok mf ← loadManagedFleet mst cachedFleet.enabled cachedFleet.boatEnabled
          cachedFleet.dailyCapCents cachedFleet.spentTodayCents cachedFleet.maxConcurrent
        | return .ok (mkJson 503 "{\"error\":\"managed_fleet_unavailable\"}")
      let nextBoatEn := if prov == "boat" then (jv.fieldBool? "enabled").getD (if req.method == "DELETE" then false else mf.boatEnabled) else mf.boatEnabled
      let nextFleetEn := Orb.ManagedProviderAvailability.fleetAfterProviderUpdate mf.enabled (jv.fieldBool? "enabled")
      let providerEnabled? := if req.method == "DELETE" then some false else jv.fieldBool? "enabled"
      let nextMaxConc := (jv.fieldUInt64? "max_concurrent").getD mf.maxConcurrent
      if let some apiKey := (jv.fieldStr? "api_key").map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
        if let .error error ← sealProviderSecret st.store.rootDir prov apiKey then
          return .ok (mkJson (if error == "managed_secret_seal_busy" then 409 else 500)
            (renderCompact (.obj #[("error", .str "managed_provider_secret_seal_failed")])))
      if let some enabled := providerEnabled?.filter (fun _ => prov != "boat") then
        if let .error error ← ManagedProviderSettings.setEnabled mst prov enabled (formatEpochIso8601Utc nowEpochSec) then
          return .ok (mkJson 500 (renderCompact (.obj #[("error", .str error)])))
      if let .error e ← saveManagedFleetConfig mst nextFleetEn nextBoatEn mf.dailyCapCents mf.spentTodayCents nextMaxConc then
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      if let .ok live ← loadManagedFleet mst nextFleetEn nextBoatEn mf.dailyCapCents mf.spentTodayCents nextMaxConc then
        st.managedRef.set live
      return .ok (mkJson 200 "{\"ok\":true}")

  if cleanPath == "/api/managed-machines/budget" && (req.method == "PUT" || req.method == "PATCH") then
    if let some (cCode, cBody) := requireAdminPrincipal caller then
      return .ok (mkJson cCode cBody)
    let some mst := st.managedStore?
      | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    let cachedFleet ← st.managedRef.get
    let .ok mf ← loadManagedFleet mst cachedFleet.enabled cachedFleet.boatEnabled
        cachedFleet.dailyCapCents cachedFleet.spentTodayCents cachedFleet.maxConcurrent
      | return .ok (mkJson 503 "{\"error\":\"managed_fleet_unavailable\"}")
    let nextEn := (jv.fieldBool? "enabled").getD mf.enabled
    let nextBoat := (jv.fieldBool? "boat_enabled").getD mf.boatEnabled
    let nextCap := (jv.fieldUInt64? "daily_cap_cents").getD mf.dailyCapCents
    let nextConc := (jv.fieldUInt64? "max_concurrent").getD mf.maxConcurrent
    if let .error e ← saveManagedFleetConfig mst nextEn nextBoat nextCap mf.spentTodayCents nextConc then
      return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    if let .ok live ← loadManagedFleet mst nextEn nextBoat nextCap mf.spentTodayCents nextConc then
      st.managedRef.set live
    return .ok (mkJson 200 "{\"ok\":true}")

  if req.method == "GET" && cleanPath == "/api/managed-machines/spend" then
    let mf ← st.managedRef.get
    let callerUidOpt := if caller.isLegacyUnscoped then none else some caller.userId
    let (infS, cmpS) ← if caller.userId.isEmpty then pure (0, 0) else getUserSpentTodayCents st.store caller.userId utcDay
    match st.managedStore? with
    | none =>
      return .ok (mkJson 200 (renderManagedBudgetJson mf callerUidOpt (infS + cmpS) caller.dailySpendCapCents?))
    | some mst =>
      match ← loadManagedFleet mst mf.enabled mf.boatEnabled mf.dailyCapCents mf.spentTodayCents mf.maxConcurrent with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok live =>
        st.managedRef.set live
        return .ok (mkJson 200 (renderManagedBudgetJson live callerUidOpt (infS + cmpS) caller.dailySpendCapCents?))

  if cleanPath == "/api/managed-machines" then
    if req.method == "GET" then
      let mf ← st.managedRef.get
      let callerUidOpt := if caller.isLegacyUnscoped then none else some caller.userId
      let (infS, cmpS) ← if caller.userId.isEmpty then pure (0, 0) else getUserSpentTodayCents st.store caller.userId utcDay
      match st.managedStore? with
      | none =>
        return .ok (mkJson 200 (renderManagedBudgetJson mf callerUidOpt (infS + cmpS) caller.dailySpendCapCents?))
      | some mst =>
        let uPrefs ← if caller.userId.isEmpty then pure #[] else getUserManagedPrefs mst caller.userId
        match ← loadManagedFleet mst mf.enabled mf.boatEnabled mf.dailyCapCents mf.spentTodayCents mf.maxConcurrent with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok live =>
          st.managedRef.set live
          let .ok catalog ← loadManagedProviderCatalog mst st.store.rootDir live (caller.role == "admin") uPrefs
              (st.managedProvisioningOverride?.map Prod.fst)
            | return .ok (mkJson 503 "{\"error\":\"managed_provider_catalog_unavailable\"}")
          let machines := (OrbBin.Json.parse (renderManagedMachinesJson live callerUidOpt
            (caller.role == "admin") uPrefs (infS + cmpS) caller.dailySpendCapCents?)).toOption.getD (.obj #[])
          return .ok (mkJson 200 (renderCompact (machines.setField "providers" catalog)))
    else if req.method == "POST" then
      if let some (cCode, cBody) := checkPlacementForCaller caller 3 0 then
        return .ok (mkJson cCode cBody)
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let rawProv := ((jv.fieldStr? "provider").getD "boat").trimAscii.toString.toLower
      let canonProv := canonicalizeProvider rawProv
      let uPrefs ← if caller.userId.isEmpty then pure #[] else getUserManagedPrefs mst caller.userId
      let prov ←
        if rawProv == "auto" then
          match knownProviders.find? (fun p => isUserManagedProviderEnabled uPrefs p) with
          | some p => pure p
          | none => return .ok (mkJson 403 "{\"error\":\"provider_disabled_for_user\",\"message\":\"No cloud providers are enabled in your preferences.\"}")
        else if !isKnownProvider canonProv then
          return .ok (mkJson 400 "{\"error\":\"unknown_provider\"}")
        else if !isUserManagedProviderEnabled uPrefs canonProv then
          return .ok (mkJson 403 "{\"error\":\"provider_disabled_for_user\",\"message\":\"This cloud provider is disabled in your preferences.\"}")
        else
          pure canonProv
      -- A retry gets its receipt back before any admission is re-run.
      let waitReady := (jv.fieldBool? "wait").getD false
      let providerRetryKey := (lookupHeaderCI req.headers "idempotency-key").getD ""
      let actionArgs := jv.setField "provider" (.str prov)
      let actionOwner : ManagedSpawnActions.Owner := {
        userId := caller.userId, missionId := (jv.fieldStr? "owner_mission_id").getD "" }
      let actionReply (accepted preview : JVal) : CoreHttpResponse :=
        let stored := (accepted.field? "result").getD (.obj #[])
        let state := (accepted.fieldStr? "state").getD ""
        if (state == "failed" || state == "uncertain") && (stored.fieldStr? "error").isSome then
          mkJson ((stored.fieldNat? "http_status").getD 409) (renderCompact
            (stored.setField "action_id" ((accepted.field? "action_id").getD .null) |>.setField "action_state" (.str state)))
        else
          -- A replay returns the first request's machine, not this request's fresh ID.
          let machine := if (stored.fieldStr? "id").isSome then stored else preview
          mkJson 202 (renderCompact (machine.setField "action_id" ((accepted.field? "action_id").getD .null)
            |>.setField "action_state" (.str state)
            |>.setField "poll_url" ((accepted.field? "poll_url").getD .null)))
      if !waitReady then
        match ← ManagedSpawnActions.replay? st.store actionOwner providerRetryKey actionArgs with
        | .error e => return .ok (mkJson 409 (renderCompact (.obj #[("error", .str e)])))
        | .ok (some prior) => return .ok (actionReply prior (.obj #[]))
        | .ok none => pure ()
      let mf0 ← st.managedRef.get
      let live ← match ← loadManagedFleet mst mf0.enabled mf0.boatEnabled mf0.dailyCapCents mf0.spentTodayCents mf0.maxConcurrent with
        | .ok l => pure l
        | .error _ => pure mf0
      let ttlMins := (jv.fieldUInt64? "ttl_minutes").getD 60
      let sz := (jv.fieldStr? "size").getD "small"
      let estCents ← match quoteManagedSpawnCents prov sz ttlMins (st.managedProvisioningOverride?.map Prod.fst) with
        | .ok cents => pure cents
        | .error e => return .ok (mkJson 400 (renderCompact (.obj #[("error", .str e)])))
      let (infS, cmpS) ← if caller.userId.isEmpty then pure (0, 0) else getUserSpentTodayCents st.store caller.userId utcDay
      let userAdmission? : Option ManagedUserAdmission := caller.dailySpendCapCents?.map fun cap => {
        capCents := cap, inferenceCents := infS, computeCents := cmpS
      }
      -- Name the real refusal: a disabled fleet or provider is not a spend cap.
      if !live.enabled then
        return .ok (mkJson 409 "{\"error\":\"managed_fleet_disabled\",\"message\":\"Managed machines are turned off for this Core.\"}")
      let providerEnabled ← match ← ManagedProviderSettings.isEnabled mst prov with
        | .ok value => pure value
        | .error e => return .ok (mkJson 503 (renderCompact (.obj #[("error", .str e)])))
      if !providerEnabled then
        return .ok (mkJson 409 (renderCompact (.obj #[("error", .str "provider_disabled"), ("provider", .str prov)])))
      let denyCode :=
        admitManagedSpawnMultiUser live estCents (infS + cmpS) caller.dailySpendCapCents? ttlMins.toUInt32
      if denyCode == 2 then
        return .ok (mkJson 429 "{\"error\":\"daily_spend_cap_exceeded\",\"scope\":\"user\"}")
      if denyCode != 0 then
        -- The shared gate also refuses a full fleet; only report a cap that is really exceeded.
        if estCents > live.dailyCapCents || live.spentTodayCents > live.dailyCapCents - estCents then
          return .ok (mkJson 429 "{\"error\":\"daily_spend_cap_exceeded\",\"scope\":\"global\"}")
        return .ok (mkJson 429 (renderCompact (.obj #[("error", .str "managed_concurrency_limit_reached"),
          ("max_concurrent", JVal.uint64 live.maxConcurrent)])))
      let defVmId ← nextUniqueId st "vm" nowEpochSec
      let vmId := (jv.fieldStr? "id").getD defVmId
      let sbName ← newManagedSandboxName ((jv.fieldStr? "name").orElse (fun _ => jv.fieldStr? "sandbox_name") |>.getD "")
      let vmRec : ManagedMachine := {
        id := vmId
        sandboxName := sbName
        provider := prov
        size := sz
        status := "provisioning"
        ownerMission := (jv.fieldStr? "owner_mission_id").getD ""
        ttlMinutes := ttlMins
        spentCents := estCents
        cordoned := false
        nodeBootEpoch := 1
        deletableAtSec := nowEpochSec
        expiresAtSec := nowEpochSec + ttlMins * 60
        ownerKind := "user"
        requestedByMissionId := (jv.fieldStr? "owner_mission_id").getD ""
        ownerUserId := caller.userId
      }
      -- A saved snapshot is restored only inside one project: the owning mission's,
      -- when the caller owns that mission; an admin may name the project directly.
      let requestedSnapshot := ((jv.fieldStr? "from_snapshot").orElse
        (fun _ => jv.fieldStr? "managed_from_snapshot") |>.getD "").trimAscii.toString
      let resolvedSnapshot ← if requestedSnapshot.isEmpty then pure "" else do
        let privileged := caller.role == "admin" || caller.isLegacyUnscoped
        let ownerMission? ← getMission? st.store vmRec.ownerMission
        let missionProject := match ownerMission? with
          | some mission => if privileged || mission.ownerUserId == caller.userId then mission.project else ""
          | none => ""
        let askedProject := ((jv.fieldStr? "project").getD "").trimAscii.toString
        let snapshotProject := if privileged && !askedProject.isEmpty then askedProject else missionProject
        let snapshotProvider ← match st.managedProvisioningOverride? with
          | some pair => pure pair.1
          | none => match ← resolveManagedProvider st.store.rootDir prov with
            | .ok p => pure p
            | .error e => return .ok (mkJson 409 (renderCompact (.obj #[("error", .str e)])))
        match ← resolveProjectSnapshot st.store snapshotProvider snapshotProject requestedSnapshot with
        | .ok name => pure name
        | .error e => return .ok (mkJson 409 (renderCompact (.obj #[("error", .str e)])))
      let work : IO (Except String JVal) := do
        match ← spawnConfiguredManagedWorker mst st.store.rootDir live vmRec jv providerRetryKey st.managedProvisioningOverride? userAdmission? resolvedSnapshot with
        | .error e => return .error e
        | .ok spawned =>
          if spawned.created && !caller.userId.isEmpty && estCents > 0 then
            discard <| addUserSpendCents st.store caller.userId utcDay 0 estCents s!"{nowEpochSec}"
          if let .ok refreshed ← loadManagedFleet mst live.enabled live.boatEnabled live.dailyCapCents (live.spentTodayCents + estCents) live.maxConcurrent then
            st.managedRef.set refreshed
          return .ok ((OrbBin.Json.parse (renderManagedMachineItemJson spawned.machine)).toOption.getD (.obj #[]))
      -- `wait: true` keeps the blocking contract (Change machine needs a ready
      -- node). Otherwise answer at once with the provisioning machine and an
      -- action to poll; readiness takes minutes.
      if waitReady then
        match ← work with
        | .error e =>
          let status := if e == "provider_at_capacity" || e == "managed_provider_availability_unavailable" then 503 else 409
          return .ok (mkJson status s!"\{\"error\":{jsonEscape e}}")
        | .ok item => return .ok (mkJson 201 (renderCompact item))
      let actionKey ← if providerRetryKey.trimAscii.toString.isEmpty then newUuidV4 else pure providerRetryKey
      let preview := (OrbBin.Json.parse (renderManagedMachineItemJson vmRec)).toOption.getD (.obj #[])
      -- What the spawn would refuse without renting is refused now, with the
      -- same status as before, so a client never sees a machine that vanishes.
      let admit := preflightConfiguredManagedSpawn mst st.store.rootDir live vmRec jv
        st.managedProvisioningOverride? resolvedSnapshot
      match ← ManagedSpawnActions.submit st.store actionOwner actionKey actionArgs work admit preview with
      | .error e =>
        let status := if e == "provider_at_capacity" || e == "managed_provider_availability_unavailable" then 503 else 409
        return .ok (mkJson status (renderCompact (.obj #[("error", .str e)])))
      | .ok accepted => return .ok (actionReply accepted preview)

  if let some params := (matchRoutePattern? "/api/managed-machines/:id/stop" rawTarget).orElse
       (fun _ => matchRoutePattern? "/api/managed-machines/:id/resume" rawTarget) then
    if req.method == "POST" then
      let vmId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let some (mRec, _) ← getManagedMachine? mst vmId
        | return .ok (mkJson 404 "{\"error\":\"managed_machine_not_found\"}")
      if !caller.isLegacyUnscoped && mRec.ownerUserId != caller.userId then
        return .ok (mkJson 404 "{\"error\":\"managed_machine_not_found\"}")
      let action := if cleanPath.endsWith "/stop" then "stop" else "resume"
      let body := req.bodySlice.toByteArray
      let .ok operationArgs := if body.isEmpty then Except.ok (.obj #[]) else OrbBin.Json.parseBytes body
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let ctx : ManagedLifecycleContext := {
        store := st.store, fleet := (← st.managedRef.get), override? := st.managedProvisioningOverride?
      }
      match ← runConfiguredManagedLifecycle mst ctx vmId action nowEpochSec operationArgs
          ((lookupHeaderCI req.headers "idempotency-key").getD "") with
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
      | .ok result =>
        let mf ← st.managedRef.get
        if let .ok live ← loadManagedFleet mst mf.enabled mf.boatEnabled mf.dailyCapCents mf.spentTodayCents mf.maxConcurrent then
          st.managedRef.set live
        return .ok (mkJson 200 (renderCompact result))

  if let some params := matchRoutePattern? "/api/managed-machines/actions/:id" rawTarget then
    if req.method == "GET" then
      let actionId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      match ← ManagedSpawnActions.read? st.store actionId { userId := caller.userId, missionId := "" }
          (caller.isLegacyUnscoped || caller.role == "admin") false with
      | .ok (some action) => return .ok (mkJson 200 (renderCompact action))
      | _ => return .ok (mkJson 404 "{\"error\":\"managed_action_not_found\"}")

  if let some params := matchRoutePattern? "/api/managed-machines/:id" rawTarget then
    let vmId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    -- Keep the provider settings/catalog routes out of the machine-ID matcher.
    let reserved := #["settings", "providers"]
    if (req.method == "DELETE" || req.method == "GET") && !reserved.contains vmId then
      let some mst := st.managedStore?
        | return .ok (mkJson 503 "{\"error\":\"managed_store_unavailable\"}")
      let some (mRec, _) ← getManagedMachine? mst vmId
        | return .ok (mkJson 404 "{\"error\":\"managed_machine_not_found\"}")
      if !caller.isLegacyUnscoped && mRec.ownerUserId != caller.userId then
        return .ok (mkJson 404 "{\"error\":\"managed_machine_not_found\"}")
      if req.method == "GET" then
        return .ok (mkJson 200 (renderManagedMachineItemJson mRec))
      let ctx : ManagedLifecycleContext := {
        store := st.store, fleet := (← st.managedRef.get), override? := st.managedProvisioningOverride?
      }
      match ← runConfiguredManagedLifecycle mst ctx vmId "destroy" nowEpochSec with
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        let mf ← st.managedRef.get
        if let .ok live ← loadManagedFleet mst mf.enabled mf.boatEnabled mf.dailyCapCents mf.spentTodayCents mf.maxConcurrent then
          st.managedRef.set live
        return .ok (mkJson 200 "{\"ok\":true}")

  if req.method == "GET" && cleanPath == "/api/remote-nodes" then
    let mf ← st.managedRef.get
    let callerUidOpt := if caller.isLegacyUnscoped then none else some caller.userId
    let (infS, cmpS) ← if caller.userId.isEmpty then pure (0, 0) else getUserSpentTodayCents st.store caller.userId utcDay
    let nowIsoRn := formatEpochIso8601Utc nowEpochSec
    match st.managedStore? with
    | none =>
      let fv ← buildComputeFleetJVal st.relayHub? none mf callerUidOpt (infS + cmpS) caller.dailySpendCapCents? st.store.rootDir nowIsoRn (some st.store)
      return .ok (mkJson 200 (renderCompact fv))
    | some mst =>
      match ← loadManagedFleet mst mf.enabled mf.boatEnabled mf.dailyCapCents mf.spentTodayCents mf.maxConcurrent with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok live =>
        st.managedRef.set live
        let fv ← buildComputeFleetJVal st.relayHub? (some mst) live callerUidOpt (infS + cmpS) caller.dailySpendCapCents? st.store.rootDir nowIsoRn (some st.store)
        return .ok (mkJson 200 (renderCompact fv))

  -- Durable follow-up queue (`GET|POST /api/control/queue`, `PATCH /api/control/queue/:id`, `POST /api/control/queue/:id/step`, `POST /api/control/queue/:id/requeue`)
  if cleanPath == "/api/control/queue" then
    if req.method == "GET" then
      let missionId := ((parseQueryParams rawTarget).find? (fun p => p.1 == "mission_id")).map Prod.snd |>.getD ""
      if missionId.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_mission_id\"}")
      if let some (cCode, cBody) := (← authorizeMissionOp st caller missionId false) then
        return .ok (mkJson cCode cBody)
      match ← listRemoteQueueJson st.store "core" missionId with
      | .ok body => return .ok (mkJson 200 body)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let missionId := (jv.fieldStr? "mission_id").getD ""
      let rawContent := (jv.fieldStr? "content").getD ""
      if missionId.isEmpty || rawContent.trimAscii.toString.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_mission_or_content\"}")
      if let some (cCode, cBody) := (← authorizeMissionOp st caller missionId false) then
        return .ok (mkJson cCode cBody)
      let defMsgId ← nextUniqueId st "qmsg" nowEpochSec
      let messageId := (jv.fieldStr? "id").getD defMsgId
      let source := (jv.fieldStr? "source").getD (if caller.isLegacyUnscoped then "control" else s!"user:{caller.username}")
      match ← enqueueStructuredFollowup st.store "core" messageId missionId rawContent source s!"{nowEpochSec}" with
      | .ok stored =>
        return .ok (mkJson 201 s!"\{\"id\":{jsonEscape messageId},\"mission_id\":{jsonEscape missionId},\"content\":{jsonEscape stored},\"source\":{jsonEscape source},\"sender_user_id\":{jsonEscape caller.userId},\"sender_username\":{jsonEscape caller.username}}")
      | .error e =>
        if e.startsWith "deferred_batch_" then
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  if let some params := matchRoutePattern? "/api/control/queue/:id/step" rawTarget then
    if req.method == "POST" then
      let messageId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !caller.isLegacyUnscoped then
        let qRows ← execParamQuery st.store.missionsDb
          "SELECT mission_id FROM remote_message_queue WHERE user_id='core' AND message_id=?1 LIMIT 1;" #[messageId]
        let qMid? := match qRows with | .ok rs => (rs[1]?.bind (·[0]?)).filter (!·.isEmpty) | .error _ => none
        match qMid? with
        | none => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
        | some qMid =>
          if let some (cCode, cBody) := (← authorizeMissionOp st caller qMid false) then
            return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let op := ((jv.fieldNat? "op").getD 0).toUInt8
      let runGen := s!"{(jv.fieldNat? "run_generation").getD 1}"
      let bootEp := s!"{(jv.fieldNat? "node_boot_epoch").map Nat.toUInt64 |>.getD st.store.bootEpoch}"
      let delivSeq := s!"{(jv.fieldNat? "delivery_seq").getD 0}"
      let uncertain : UInt8 := if (jv.fieldBool? "uncertain_timeout").getD false then 1 else ((jv.fieldNat? "uncertain_timeout").getD 0).toUInt8
      let opConfirm : UInt8 := if (jv.fieldBool? "operator_confirmed").getD false then 1 else ((jv.fieldNat? "operator_confirmed").getD 0).toUInt8
      let nextContent := (jv.fieldStr? "content").getD ""
      match ← stepQueueItem st.store "core" messageId op runGen bootEp delivSeq s!"{nowEpochSec}" uncertain opConfirm nextContent with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok .notFound => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
      | .ok (.rejected reason) => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
      | .ok (.ok rec) =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape rec.messageId},\"mission_id\":{jsonEscape rec.missionId},\"phase\":{rec.phase.toNat},\"phase_name\":{jsonEscape (queuePhaseName rec.phase)},\"delivered_seq\":{rec.deliveredSeq}}")

  if let some params := matchRoutePattern? "/api/control/queue/:id/requeue" rawTarget then
    if req.method == "POST" then
      let messageId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !caller.isLegacyUnscoped then
        let qRows ← execParamQuery st.store.missionsDb
          "SELECT mission_id FROM remote_message_queue WHERE user_id='core' AND message_id=?1 LIMIT 1;" #[messageId]
        let qMid? := match qRows with | .ok rs => (rs[1]?.bind (·[0]?)).filter (!·.isEmpty) | .error _ => none
        match qMid? with
        | none => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
        | some qMid =>
          if let some (cCode, cBody) := (← authorizeMissionOp st caller qMid false) then
            return .ok (mkJson cCode cBody)
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let opConfirm : UInt8 := if (jv.fieldBool? "operator_confirmed").getD false then 1 else ((jv.fieldNat? "operator_confirmed").getD 0).toUInt8
      match ← stepQueueItem st.store "core" messageId 4 "0" s!"{st.store.bootEpoch}" "0" s!"{nowEpochSec}" 0 opConfirm "" with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok .notFound => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
      | .ok (.rejected reason) => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
      | .ok (.ok rec) =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape rec.messageId},\"phase\":{rec.phase.toNat}}")

  if cleanPath.startsWith "/api/control/queue/" && cleanPath.endsWith "/send-now" then
    let sHub ← match st.systemHub? with | some h => pure h | none => newSystemRuntimeHub
    if let some (sCode, sCtype, sBody) ← dispatchResourcesAndSystemRoute
        sHub st.store st.cfg.workingDir st.cfg.libraryRemote st.cfg.githubClientId
        st.bunkerStateRef? st.managedStore? st.relayHub? st.broadcastHub?
        req.method cleanPath rawTarget req.headers req.bodySlice.toByteArray
        caller.userId caller.username st.bootstrapAdminId
        (caller.isLegacyUnscoped || caller.role == "admin") caller.isLegacyUnscoped then
      return .ok { status := sCode, contentType := sCtype, corsOrigin? := reqOrigin?, body := sBody }

  if let some params := matchRoutePattern? "/api/control/queue/:id" rawTarget then
    if req.method == "PATCH" then
      let messageId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !caller.isLegacyUnscoped then
        let qRows ← execParamQuery st.store.missionsDb
          "SELECT mission_id FROM remote_message_queue WHERE user_id='core' AND message_id=?1 LIMIT 1;" #[messageId]
        let qMid? := match qRows with | .ok rs => (rs[1]?.bind (·[0]?)).filter (!·.isEmpty) | .error _ => none
        match qMid? with
        | none => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
        | some qMid =>
          if let some (cCode, cBody) := (← authorizeMissionOp st caller qMid false) then
            return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let some rawContent := jv.fieldStr? "content"
        | return .ok (mkJson 400 "{\"error\":\"content must be a string\"}")
      let content := rawContent.trimAscii.toString
      if content.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"A queued message cannot be empty; remove it instead\"}")
      match ← editRemoteMessage st.store "core" messageId content with
      | .error e =>
        if e.startsWith "deferred_batch_" then
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok .NotFound => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
      | .ok .AlreadyDelivered =>
        return .ok (mkJson 409 "{\"error\":\"This message was already sent; it can no longer be edited\"}")
      | .ok (.Edited missionId source?) =>
        let sourceJson := match source? with | some s => jsonEscape s | none => "null"
        let eventPayload := s!"\{\"type\":\"user_message\",\"id\":{jsonEscape messageId},\"content\":{jsonEscape content},\"queued\":true,\"mission_id\":{jsonEscape missionId},\"source\":{sourceJson},\"sender_user_id\":{jsonEscape caller.userId},\"sender_username\":{jsonEscape caller.username}}"
        let _ ← appendMissionEvent st.store missionId "user_message" eventPayload s!"{nowEpochSec}"
        return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape messageId},\"content\":{jsonEscape content}}")

  -- Mission Cyber Access (`GET|PATCH /api/control/missions/:id/cyber`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/cyber" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
    if let some (cCode, cBody) := (← authorizeMissionOp st caller mid (req.method != "GET")) then
      return .ok (mkJson cCode cBody)
    let some mission ← getMission? st.store mid
      | return .ok (mkJson 404 "{\"error\":\"Mission not found\"}")
    if req.method == "GET" then
      match ← readSelection st.cfg.workingDir mid with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok sel =>
        let outBody ← match ← readReceipt? st.cfg.workingDir mid with
          | some r =>
            if receiptIsCurrent mission.backend mission.modelOverride false sel r then
              pure (confirmedResponse sel r)
            else pure (selectionResponse sel)
          | none => pure (selectionResponse sel)
        return .ok (mkJson 200 outBody)
    else if req.method == "PATCH" then
      if mission.backend != "codex" then
        return .ok (mkJson 400 "{\"error\":\"Cyber selection is available for Codex only.\"}")
      if !(← isMissionIdleForCyberChange st mission) then
        return .ok (mkJson 409 "{\"error\":\"Stop the running turn before changing Cyber Access; the choice applies on the next launch.\"}")
      let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD ""
      let .ok (.obj fields) := OrbBin.Json.parse rawBody
        | return .ok (mkJson 400 "{\"error\":\"invalid_cyber_mode\"}")
      if fields.any (fun (k, _) => k != "mode" && k != "expected_revision") then
        return .ok (mkJson 400 "{\"error\":\"unknown_cyber_field\"}")
      let some rawMode := (fields.find? (fun (k, _) => k == "mode")).bind (fun p => p.2.asStr?)
        | return .ok (mkJson 400 "{\"error\":\"invalid_cyber_mode\"}")
      let some mode := parseMode? rawMode
        | return .ok (mkJson 400 "{\"error\":\"invalid_cyber_mode\"}")
      if let some expRev := (fields.find? (fun (k, _) => k == "expected_revision")).bind (fun p => p.2.asStr?) then
        let cur ← match ← readSelection st.cfg.workingDir mid with
          | .ok s => pure s
          | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        if cur.revision != expRev then
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape clientSelectionConflict}}")
      let effectiveModel := if mission.modelOverride.isEmpty then defaultCodexModel else mission.modelOverride
      if let .error e := mode.program effectiveModel then
        return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
      let rawRev ← newUuidV4
      let sel : Selection := { mode := mode, revision := (parseUuidCanonical? rawRev).getD rawRev }
      match ← writePending st.cfg.workingDir mid sel with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok () => return .ok (mkJson 200 (selectionResponse sel))

  -- Cyber capability probe (`GET /api/control/cyber-capabilities`)
  if req.method == "GET" && cleanPath == "/api/control/cyber-capabilities" then
    let q := parseQueryParams rawTarget
    let model? := ((q.find? (fun p => p.1 == "model")).map Prod.snd).filter (fun s => !s.trimAscii.toString.isEmpty)
    let mode := ((q.find? (fun p => p.1 == "mode")).bind (fun p => parseMode? p.2)).getD .standard
    let remote := ((q.find? (fun p => p.1 == "remote")).map Prod.snd).getD "" == "true"
    return .ok (mkJson 200 (capabilitiesJson remote mode model?))

  -- Mission Follow-up Message (`POST /api/control/message`)
  if req.method == "POST" && cleanPath == "/api/control/message" then
    let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD "{}"
    let bodyJv := (OrbBin.Json.parse rawBody).toOption.getD (.obj #[])
    let content := (bodyJv.fieldStr? "content").getD ""
    let mid? := (bodyJv.fieldStr? "mission_id").filter (fun s => !s.isEmpty)
    if let some mid := mid? then
      if !isSafeMissionId mid then
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      if (← isCloudMission st.store mid) then
        let cHub ← match st.cloudHub? with | some h => pure h | none => newCloudRuntimeHub
        let (fCode, fCtype, fBody) ← handleCloudFollowUp cHub st.store st.broadcastHub? st.cfg.port mid bodyJv
        return .ok { status := fCode, contentType := fCtype, corsOrigin? := reqOrigin?, body := fBody }
    let defMsgId ← nextUniqueId st "msg" nowEpochSec
    let msgId := (bodyJv.fieldStr? "client_message_id").getD defMsgId
    let mission? ← match mid? with
      | some mid => getMission? st.store mid
      | none => pure none
    let mut promoteCyber? : Option (String × Selection × String) := none
    if let some mid := mid? then
      if let some m := mission? then
        if m.backend == "codex" then
          if let .error e := validateGoalMessage content (bodyHasImages bodyJv) then
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          let isIdle ← isMissionIdleForCyberChange st m
          let saved ← match ← (if isIdle then readSelection st.cfg.workingDir mid else readCommittedSelection st.cfg.workingDir mid) with
            | .ok s => pure s
            | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
          let effectiveModel := if m.modelOverride.isEmpty then defaultCodexModel else m.modelOverride
          if let .error e := saved.mode.program effectiveModel then
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          if (parseGoalPrefix? content).isSome then
            if let .error e := validateGoalSelection saved.mode true then
              return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          let reqMode? ← match bodyJv.fieldStr? "cyber_access" with
            | none => pure none
            | some rawCyber =>
              match parseMode? rawCyber with
              | some rm => pure (some rm)
              | none => return .ok (mkJson 400 "{\"error\":\"invalid_cyber_mode\"}")
          let reqRev? := bodyJv.fieldStr? "cyber_revision"
          if isIdle && saved.mode != .automatic then
            if let .error e := validateClientSelection saved reqMode? reqRev? then
              return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
          else if reqMode?.isSome || reqRev?.isSome then
            if let some rm := reqMode? then
              if rm != saved.mode then
                return .ok (mkJson 409 s!"\{\"error\":{jsonEscape clientSelectionConflict}}")
            if let some rr := reqRev? then
              if rr != saved.revision then
                return .ok (mkJson 409 s!"\{\"error\":{jsonEscape clientSelectionConflict}}")
          if isIdle && saved.revision != nilRevision then
            promoteCyber? := some (mid, saved, effectiveModel)
    let mut selectedSkills : Array SelectedSkill := #[]
    if !(references content).isEmpty then
      let proj? := mission?.bind (fun m =>
        if m.project.isEmpty then none
        else if caller.isLegacyUnscoped then some m.project
        else some ((unscopeProjectSlugForOwner m.ownerUserId st.bootstrapAdminId m.project).getD m.project))
      let harness := (mission?.map (·.backend)).getD "opencode"
      match ← selectDelivered st.cfg.workingDir proj? harness content with
      | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
      | .ok sel => selectedSkills := sel
    if let some (mid, saved, effectiveModel) := promoteCyber? then
      match ← promote st.cfg.workingDir mid saved.mode saved.revision with
      | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
      | .ok promoted =>
        if promoted.mode != .automatic then
          discard <| writeBinding st.cfg.workingDir mid {
            revision := promoted.revision, key := s!"remote-launch:{mid}", model := effectiveModel
          }
    let nowIso := formatEpochIso8601Utc nowEpochSec
    let delivContent := if selectedSkills.isEmpty then content else withDirective content selectedSkills
    let mut queued := false
    let mut dispatchedRemote := false
    if let some mid := mid? then
      let evPayload :=
        s!"\{\"type\":\"user_message\",\"id\":{jsonEscape msgId},\"content\":{jsonEscape content}," ++
        s!"\"mission_id\":{jsonEscape mid},\"sender_user_id\":{jsonEscape caller.userId},\"sender_username\":{jsonEscape caller.username}}"
      if let (some sup, some m, some targetNode) := (st.remoteSup?, mission?, ← resolveMissionRemoteNode? st.store st.managedStore? mid) then
        dispatchedRemote := true
        if m.status == "active" || m.status == "pending" then
          discard <| enqueueStructuredFollowup st.store "core" msgId mid delivContent "control" nowIso
          queued := true
        else
          let _ ← appendMissionEvent st.store mid "user_message" evPayload nowIso
          let mut resumeSid? : Option String := none
          if let .ok sRows ← execParamQuery st.store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
            if sRows.size > 1 then
              let s := (cell sRows[1]! 0).trimAscii.toString
              if !s.isEmpty then resumeSid? := some s
          let isSide := (OrbBin.Json.parse m.tagsJson).toOption.bind JVal.asArr? |>.getD #[] |>.any (fun v => v.asStr? == some "side-question")
          let spec : RemoteTurnSpec := {
            missionId        := mid
            targetNodeId     := targetNode
            backend          := m.backend
            modelOverride    := if m.backend == "opencode" && m.modelOverride.isEmpty then "builtin/smart" else m.modelOverride
            modelEffort      := m.modelEffort
            workingDirectory := m.workingDirectory
            project          := m.project
            ownerUserId      := m.ownerUserId
            authorityMode    := m.authorityMode
            placementKind    := m.placementKind
            reservedDiskGib  := m.reservedDiskGib
            tagsJson         := m.tagsJson
            prompt           := delivContent
            resumeSessionId? := resumeSid?
            sideQuestion     := isSide
          }
          if let .error dispErr ← submitRemoteMissionTurn st.store st.managedStore? st.relayHub? st.broadcastHub? sup st.cfg.workingDir spec nowEpochSec then
            return .ok (mkJson 502 s!"\{\"error\":{jsonEscape dispErr}}")
      else
        let _ ← appendMissionEvent st.store mid "user_message" evPayload nowIso
      if let some tSink := st.telemetrySink? then
        let actorUid? := if caller.isLegacyUnscoped || caller.userId.isEmpty then none else some caller.userId
        let actorUname? := if caller.isLegacyUnscoped || caller.username.isEmpty then none else some caller.username
        observeControlUserPrompt tSink (caller.role == "admin") actorUid? actorUname? mid content nowEpochSec
    let deliveredField :=
      if selectedSkills.isEmpty then ""
      else s!",\"delivered_prompt\":{jsonEscape delivContent}"
    if !dispatchedRemote then
      if let (some mid, some m) := (mid?, mission?) then
        let isSide := (OrbBin.Json.parse m.tagsJson).toOption.bind JVal.asArr? |>.getD #[] |>.any (fun v => v.asStr? == some "side-question")
        let spawnWanted :=
          (bodyJv.fieldBool? "spawn_harness").getD
            (m.placementKind == "managed" && !isCloudBackendName m.backend && !content.trimAscii.toString.isEmpty)
        if spawnWanted || (isSide && m.placementKind != "client" && st.warmMgr?.isSome) then
          let permMode := (bodyJv.fieldStr? "permission_mode").getD (if isSide then "bypassPermissions" else "supervised")
          if isSide then
            let mut sid? : Option String := none
            if let .ok sRows ← execParamQuery st.store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
              if sRows.size > 1 then
                let s := (cell sRows[1]! 0).trimAscii.toString
                if !s.isEmpty then sid? := some s
            discard <| launchLocalCoreMissionTurn st mid m.backend m.workingDirectory delivContent m.modelOverride m.modelEffort permMode sid? "local" false
          else
            discard <| maybeSpawnWarmHarnessTurn st caller m.placementKind mid m.backend m.workingDirectory delivContent m.modelOverride m.modelEffort permMode "" false
    return .ok (mkJson 200 (
      s!"\{\"id\":{jsonEscape msgId},\"queued\":{if queued then "true" else "false"},\"message_accepted\":true," ++
      s!"\"sender_user_id\":{jsonEscape caller.userId},\"sender_username\":{jsonEscape caller.username}{deliveredField}}"))

  -- Mission Resume (`POST /api/control/missions/:id/resume`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/resume" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      if let some (cCode, cBody) := (← authorizeMissionOp st caller mid false) then
        return .ok (mkJson cCode cBody)
      let some m ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"Mission not found\"}")
      if !caller.isLegacyUnscoped then
        let mTags : Array String :=
          match OrbBin.Json.parse m.tagsJson with
          | .ok (.arr xs) => xs.filterMap JVal.asStr?
          | _ => #[]
        let (resTKind, resNAdmin) := classifyMissionPlacementTarget (m.placementKind == "client") m.placementKind none mTags
        if let some (cCode, cBody) := checkPlacementForCaller caller resTKind resNAdmin then
          return .ok (mkJson cCode cBody)
      let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD "{}"
      let bodyJv := (OrbBin.Json.parse rawBody).toOption.getD (.obj #[])
      let content? := bodyJv.fieldStr? "content"
      let mut promoteCyber? : Option (Selection × String) := none
      if m.backend == "codex" then
        if let some content := content? then
          if let .error e := validateGoalMessage content (bodyHasImages bodyJv) then
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        let saved ← match ← readSelection st.cfg.workingDir mid with
          | .ok s => pure s
          | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        let effectiveModel := if m.modelOverride.isEmpty then defaultCodexModel else m.modelOverride
        if let .error e := saved.mode.program effectiveModel then
          return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        let resumesGoal := (content?.bind parseGoalPrefix?).isSome ||
          ((bodyJv.fieldBool? "goal_mode").getD false && content?.isNone)
        if resumesGoal then
          if let .error e := validateGoalSelection saved.mode true then
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
        if (← isMissionIdleForCyberChange st m) && saved.revision != nilRevision then
          promoteCyber? := some (saved, effectiveModel)
      let mut selectedSkills : Array SelectedSkill := #[]
      if let some content := content? then
        if !(references content).isEmpty then
          let proj? :=
            if m.project.isEmpty then none
            else if caller.isLegacyUnscoped then some m.project
            else some ((unscopeProjectSlugForOwner m.ownerUserId st.bootstrapAdminId m.project).getD m.project)
          match ← selectDelivered st.cfg.workingDir proj? m.backend content with
          | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          | .ok sel => selectedSkills := sel
      if let some (saved, effectiveModel) := promoteCyber? then
        match ← promote st.cfg.workingDir mid saved.mode saved.revision with
        | .error e => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape e}}")
        | .ok promoted =>
          if promoted.mode != .automatic then
            discard <| writeBinding st.cfg.workingDir mid {
              revision := promoted.revision, key := s!"remote-launch:{mid}", model := effectiveModel
            }
      let deliveredField :=
        match content? with
        | some c =>
          if selectedSkills.isEmpty then ""
          else s!",\"delivered_prompt\":{jsonEscape (withDirective c selectedSkills)}"
        | none => ""
      let rawPrompt := content?.getD "Continue."
      let deliv := if selectedSkills.isEmpty then rawPrompt else withDirective rawPrompt selectedSkills
      let nowIso := formatEpochIso8601Utc nowEpochSec
      if let (some sup, some targetNode) := (st.remoteSup?, ← resolveMissionRemoteNode? st.store st.managedStore? mid) then
        if m.status != "active" && m.status != "pending" then
          discard <| appendMissionEvent st.store mid "user_message"
            (renderCompact (.obj #[("type", .str "user_message"), ("content", .str rawPrompt), ("mission_id", .str mid)])) nowIso
          let mut resumeSid? : Option String := none
          if let .ok sRows ← execParamQuery st.store.missionsDb "SELECT COALESCE(session_id,'') FROM missions WHERE id=?1;" #[mid] then
            if sRows.size > 1 then
              let s := (cell sRows[1]! 0).trimAscii.toString
              if !s.isEmpty then resumeSid? := some s
          let spec : RemoteTurnSpec := {
            missionId        := mid
            targetNodeId     := targetNode
            backend          := m.backend
            modelOverride    := if m.backend == "opencode" && m.modelOverride.isEmpty then "builtin/smart" else m.modelOverride
            modelEffort      := m.modelEffort
            workingDirectory := m.workingDirectory
            project          := m.project
            ownerUserId      := m.ownerUserId
            authorityMode    := m.authorityMode
            placementKind    := m.placementKind
            reservedDiskGib  := m.reservedDiskGib
            tagsJson         := m.tagsJson
            prompt           := deliv
            resumeSessionId? := resumeSid?
          }
          if let .error dispErr ← submitRemoteMissionTurn st.store st.managedStore? st.relayHub? st.broadcastHub? sup st.cfg.workingDir spec nowEpochSec then
            return .ok (mkJson 502 s!"\{\"error\":{jsonEscape dispErr}}")
      else
        let spawnWanted := (bodyJv.fieldBool? "spawn_harness").getD false
        if spawnWanted then
          let permMode := (bodyJv.fieldStr? "permission_mode").getD "supervised"
          discard <| maybeSpawnWarmHarnessTurn st caller m.placementKind mid m.backend m.workingDirectory deliv m.modelOverride m.modelEffort permMode "" true
      return .ok (mkJson 200 s!"\{\"id\":{jsonEscape mid},\"status\":\"active\"{deliveredField}}")

  -- Delivered skill catalog (`GET /api/library/skill-delivery`)
  if req.method == "GET" && cleanPath == "/api/library/skill-delivery" then
    let q := parseQueryParams rawTarget
    let proj? := (q.find? (fun p => p.1 == "project")).map Prod.snd
    match ← buildDeliveryPlan st.cfg.workingDir proj? with
    | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
    | .ok plan => return .ok (mkJson 200 (planToJson plan))

  -- Nonce-bound CLIProxy OAuth login & generation-fenced credential rotation (`SM-21`, `R1-02`, `R1-03`)
  if cleanPath.startsWith "/api/control/auth/" then
    if !caller.isLegacyUnscoped then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
    let effAuthRoot :=
      if !st.authRoot.trimAscii.toString.isEmpty then st.authRoot
      else
        let normWork := trimTrailingSlashes st.cfg.workingDir.trimAscii.toString
        if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then s!"{normWork}/auth"
        else s!"{normWork}/.sandboxed-sh/auth"

    if req.method == "POST" && cleanPath == "/api/control/auth/cliproxy/login" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let provider := (jv.fieldStr? "provider").getD ""
      let nonce := ((jv.fieldNat? "attempt_nonce").getD 0).toUInt64
      let ttlSecs := ((jv.fieldNat? "ttl_secs").getD 300).toUInt64
      let expiresAt :=
        match jv.fieldNat? "expires_at" with
        | some e => e.toUInt64
        | none => nowEpochSec + (if ttlSecs == 0 then 300 else ttlSecs)
      match validateCliProxyLoginParams effAuthRoot provider nonce nowEpochSec expiresAt with
      | .error reason =>
        return .ok (mkJson 400 s!"\{\"error\":{jsonEscape reason}}")
      | .ok candSess =>
        let admission ← match st.cliProxySessionsRef? with
          | none => pure CliProxySessionAdmission.admittedNew
          | some sRef =>
            sRef.modifyGet fun xs =>
              admitOrRefreshCliProxySession xs candSess nowEpochSec maxCliProxyLoginSessions
        match admission with
        | .duplicateNonceProviderConflict =>
          return .ok (mkJson 409 "{\"error\":\"duplicate_attempt_nonce\"}")
        | .capacityExceeded =>
          return .ok (mkJson 429 "{\"error\":\"too_many_active_login_sessions\"}")
        | .admittedNew =>
          match ← beginCliProxyLogin effAuthRoot provider nonce nowEpochSec expiresAt with
          | .error reason =>
            if let some sRef := st.cliProxySessionsRef? then
              sRef.modify fun xs =>
                xs.filter (fun s => !(s.attemptNonce == candSess.attemptNonce && s.provider == candSess.provider && s.startedAtEpoch == candSess.startedAtEpoch && s.expiresAtEpoch == candSess.expiresAtEpoch))
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape reason}}")
          | .ok sess =>
            return .ok (mkJson 201 s!"\{\"ok\":true,\"attempt_nonce\":{sess.attemptNonce},\"provider\":{jsonEscape sess.provider},\"attempt_dir\":{jsonEscape sess.attemptDir},\"credential_path\":{jsonEscape (sess.credentialPath sess.provider)},\"started_at\":{sess.startedAtEpoch},\"expires_at\":{sess.expiresAtEpoch}}")
        | .refreshedSameProvider prevSess =>
          match ← beginCliProxyLogin effAuthRoot provider nonce nowEpochSec expiresAt with
          | .error reason =>
            if let some sRef := st.cliProxySessionsRef? then
              sRef.modify fun xs =>
                xs.map (fun s => if s.attemptNonce == prevSess.attemptNonce then prevSess else s)
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape reason}}")
          | .ok sess =>
            return .ok (mkJson 201 s!"\{\"ok\":true,\"attempt_nonce\":{sess.attemptNonce},\"provider\":{jsonEscape sess.provider},\"attempt_dir\":{jsonEscape sess.attemptDir},\"credential_path\":{jsonEscape (sess.credentialPath sess.provider)},\"started_at\":{sess.startedAtEpoch},\"expires_at\":{sess.expiresAtEpoch}}")

    if req.method == "POST" && cleanPath == "/api/control/auth/cliproxy/stage" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let sessNonce := ((jv.fieldNat? "session_nonce").orElse (fun _ => jv.fieldNat? "attempt_nonce") |>.getD 0).toUInt64
      let presentedNonce := ((jv.fieldNat? "presented_nonce").orElse (fun _ => jv.fieldNat? "attempt_nonce") |>.getD 0).toUInt64
      let provider := (jv.fieldStr? "provider").getD ""
      let credJson :=
        match jv.field? "credential" with
        | some obj@(.obj _) => renderCompact obj
        | _ => (jv.fieldStr? "credential_json").getD ""
      let sess? ← match st.cliProxySessionsRef? with
        | some sRef =>
          sRef.modifyGet fun xs =>
            let live := xs.filter (fun s => nowEpochSec < s.expiresAtEpoch)
            (live.find? (fun s => s.attemptNonce == sessNonce), live)
        | none => pure none
      let some sess := sess?
        | return .ok (mkJson 404 "{\"error\":\"login_session_not_found\"}")
      match ← stageCliProxyCredential sess presentedNonce provider credJson nowEpochSec with
      | .error reason =>
        return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
      | .ok stagedPath =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"attempt_nonce\":{sess.attemptNonce},\"provider\":{jsonEscape provider},\"staged_path\":{jsonEscape stagedPath}}")

    if req.method == "GET" && cleanPath == "/api/control/auth/cliproxy/staged" then
      let qParams := parseQueryParams rawTarget
      let sessNonce := ((qParams.find? (fun p => p.1 == "session_nonce" || p.1 == "attempt_nonce")).bind (fun p => p.2.toNat?) |>.getD 0).toUInt64
      let presentedNonce := ((qParams.find? (fun p => p.1 == "presented_nonce" || p.1 == "attempt_nonce")).bind (fun p => p.2.toNat?) |>.getD 0).toUInt64
      let provider := ((qParams.find? (fun p => p.1 == "provider")).map Prod.snd).getD ""
      let sess? ← match st.cliProxySessionsRef? with
        | some sRef =>
          sRef.modifyGet fun xs =>
            let live := xs.filter (fun s => nowEpochSec < s.expiresAtEpoch)
            (live.find? (fun s => s.attemptNonce == sessNonce), live)
        | none => pure none
      let some sess := sess?
        | return .ok (mkJson 404 "{\"error\":\"login_session_not_found\"}")
      match ← readStagedCliProxyCredential sess presentedNonce provider with
      | .error reason =>
        return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
      | .ok rawCred =>
        return .ok (mkJson 200 s!"\{\"ok\":true,\"attempt_nonce\":{sess.attemptNonce},\"provider\":{jsonEscape provider},\"credential_json\":{jsonEscape rawCred}}")

    if req.method == "POST" && cleanPath == "/api/control/auth/cliproxy/promote" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let sessNonce := ((jv.fieldNat? "session_nonce").orElse (fun _ => jv.fieldNat? "attempt_nonce") |>.getD 0).toUInt64
      let presentedNonce := ((jv.fieldNat? "presented_nonce").orElse (fun _ => jv.fieldNat? "attempt_nonce") |>.getD 0).toUInt64
      let provider := (jv.fieldStr? "provider").getD ""
      let sess? ← match st.cliProxySessionsRef? with
        | some sRef =>
          sRef.modifyGet fun xs =>
            let live := xs.filter (fun s => nowEpochSec < s.expiresAtEpoch)
            (live.find? (fun s => s.attemptNonce == sessNonce), live)
        | none => pure none
      let some sess := sess?
        | return .ok (mkJson 404 "{\"error\":\"login_session_not_found\"}")
      match ← promoteCliProxyCredential sess presentedNonce provider nowEpochSec with
      | .error reason =>
        return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
      | .ok promotedPath =>
        if let some sRef := st.cliProxySessionsRef? then
          sRef.modify fun xs =>
            xs.filter (fun s => nowEpochSec < s.expiresAtEpoch && !(s.attemptNonce == sess.attemptNonce && s.provider == sess.provider))
        return .ok (mkJson 200 s!"\{\"ok\":true,\"attempt_nonce\":{sess.attemptNonce},\"provider\":{jsonEscape provider},\"promoted_path\":{jsonEscape promotedPath}}")

    if cleanPath.startsWith "/api/control/auth/rotation" then
      let some rotH := st.authRotation?
        | return .ok (mkJson 503 "{\"error\":\"auth_rotation_unavailable\"}")
      let renderLedger (led : AuthRotationLedger) (drained : Array String := #[]) : String :=
        let drainedJson := String.intercalate "," (drained.toList.map jsonEscape)
        let pendingJson := String.intercalate "," (led.rotation.pendingRotations.toList.map (fun r =>
          s!"\{\"applied_gen\":{r.appliedGen},\"record_path\":{jsonEscape r.recordPath}}"))
        s!"\{\"ok\":true,\"phase_code\":{led.rotation.phaseCode.toNat},\"dirty_pending\":{led.rotation.dirtyPending.toNat},\"durable_auth_generation\":{led.rotation.durableAuthGeneration},\"active_login_nonce\":{led.rotation.activeLoginNonce},\"token_expiry\":{led.rotation.tokenExpiryEpoch},\"writer_dirty\":{if led.writer.dirty then "true" else "false"},\"dirty_seq\":{led.writer.dirtySeq},\"flushed_seq\":{led.writer.flushedSeq},\"pending_rotations\":[{pendingJson}],\"drained_paths\":[{drainedJson}]}"

      if req.method == "GET" && cleanPath == "/api/control/auth/rotation" then
        let led ← snapshotRotationLedger rotH
        return .ok (mkJson 200 (renderLedger led))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/claim" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let nonce := ((jv.fieldNat? "attempt_nonce").getD 0).toUInt64
        let leaseDl := ((jv.fieldNat? "lease_deadline").getD 0).toUInt64
        match ← claimAuthRefreshLive rotH nonce nowEpochSec leaseDl with
        | .error reason => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok _ =>
          let led ← snapshotRotationLedger rotH
          return .ok (mkJson 200 (renderLedger led))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/stage" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let candGen := ((jv.fieldNat? "candidate_gen").getD 0).toUInt64
        let presNonce := ((jv.fieldNat? "presented_nonce").orElse (fun _ => jv.fieldNat? "attempt_nonce") |>.getD 0).toUInt64
        let recName := (jv.fieldStr? "record_name").getD s!"pending-gen-{candGen}.json"
        if recName.trimAscii.toString.isEmpty || hasSegmentTraversal recName then
          return .ok (mkJson 400 "{\"error\":\"invalid_record_name\"}")
        let recPath := s!"{effAuthRoot}/rotations/{recName}"
        let payloadStr? : Option String :=
          match jv.field? "payload" with
          | some obj@(.obj _) => some (renderCompact obj)
          | _ => jv.fieldStr? "payload_json"
        let seq? := (jv.fieldNat? "seq").map Nat.toUInt64
        let payloadBytes? := payloadStr?.map String.toUTF8
        match ← stageAuthRotationLive rotH candGen presNonce nowEpochSec recPath payloadBytes? seq? payloadBytes? with
        | .error reason => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok _ =>
          let led ← snapshotRotationLedger rotH
          return .ok (mkJson 200 (renderLedger led))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/record-pending" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let appGen := ((jv.fieldNat? "applied_gen").getD 0).toUInt64
        let recName := (jv.fieldStr? "record_name").getD s!"pending-gen-{appGen}.json"
        if recName.trimAscii.toString.isEmpty || hasSegmentTraversal recName then
          return .ok (mkJson 400 "{\"error\":\"invalid_record_name\"}")
        let recPath := s!"{effAuthRoot}/rotations/{recName}"
        let payloadStr :=
          match jv.field? "payload" with
          | some obj@(.obj _) => renderCompact obj
          | _ => (jv.fieldStr? "payload_json").getD s!"\{\"gen\":{appGen}}"
        let coalesceWriter := (jv.fieldBool? "coalesce_writer").getD false
        let seq? := (jv.fieldNat? "seq").map Nat.toUInt64
        match ← recordPendingRotationLive rotH appGen recPath (some payloadStr.toUTF8) coalesceWriter seq? with
        | .error reason => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok _ =>
          let led ← snapshotRotationLedger rotH
          return .ok (mkJson 200 (renderLedger led))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/commit" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let candGen := ((jv.fieldNat? "candidate_gen").getD 0).toUInt64
        let newExpiry : UInt64 := ((jv.fieldNat? "new_expiry").map Nat.toUInt64).getD (nowEpochSec + 3600)
        let snap ← snapshotRotationLedger rotH
        let expectedSeq := ((jv.fieldNat? "expected_seq").map Nat.toUInt64).getD snap.writer.dirtySeq
        let wArg := { snap.writer with dirtySeq := expectedSeq }
        let stArg :=
          match jv.fieldNat? "expected_gen" with
          | some g => { snap.rotation with durableAuthGeneration := g.toUInt64 }
          | none => snap.rotation
        match ← commitAndDrainRotation stArg wArg candGen nowEpochSec newExpiry false false (some rotH) with
        | .error reason =>
          return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok (_, _, drainedPaths, _) =>
          let led ← snapshotRotationLedger rotH
          return .ok (mkJson 200 (renderLedger led drainedPaths))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/abort" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let candGen := ((jv.fieldNat? "candidate_gen").getD 0).toUInt64
        match ← abortAuthRefreshLive rotH candGen nowEpochSec with
        | .error reason => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok _ =>
          let led ← snapshotRotationLedger rotH
          return .ok (mkJson 200 (renderLedger led))

      if req.method == "POST" && cleanPath == "/api/control/auth/rotation/revoke" then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        let candGen := ((jv.fieldNat? "candidate_gen").getD 0).toUInt64
        match ← revokeAuthCredentialLive rotH candGen nowEpochSec with
        | .error reason => return .ok (mkJson 409 s!"\{\"error\":{jsonEscape reason}}")
        | .ok _ =>
            let led ← snapshotRotationLedger rotH
            return .ok (mkJson 200 (renderLedger led))

  -- Inbox Single-Owner CAS (`GET /api/control/inbox-state`, `PUT /api/control/inbox-state/*`, `SM-18`)
  if cleanPath == "/api/control/inbox-state" && req.method == "GET" then
    let inboxUidOpt := if caller.isLegacyUnscoped then none else some caller.userId
    match ← readInboxStateJson st.store inboxUidOpt with
    | .ok body => return .ok (mkJson 200 body)
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  if cleanPath.startsWith "/api/control/inbox-state/" && req.method == "PUT" then
    let subPath := (cleanPath.drop 25).toString
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    match parseInboxPut subPath jv with
    | .error "unknown_inbox_path" => return .ok (mkJson 404 "{\"error\":\"unknown_inbox_path\"}")
    | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
    | .ok putReq =>
      let inboxUidOpt := if caller.isLegacyUnscoped then none else some caller.userId
      let (code, body) ← putInboxState st.store putReq inboxUidOpt
      return .ok (mkJson code body)

  -- Project Context Replica Endpoints (`/api/projects/:project/context/*`, `SM-18`) and Tracks/Board (`SM-13`)
  if cleanPath.startsWith "/api/projects/" then
    let afterPfx := (cleanPath.drop 14).toString
    let segs := afterPfx.splitOn "/"
    let resolveCallerProj (rawSeg : String) : Option String := do
      let dec ← percentDecodeStrict rawSeg
      if dec.isEmpty then none
      else if caller.isLegacyUnscoped then
        if validProjectSlug dec then some dec else none
      else
        scopeProjectSlug caller.userId st.bootstrapAdminId dec
    let recordCallerProj (scopedProj : String) : IO Unit := do
      if !caller.isLegacyUnscoped && !caller.userId.isEmpty then
        discard <| execParamQuery st.store.projectsDb
          "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
          #[scopedProj, caller.userId, s!"{nowEpochSec}"]
    match segs with
    | [rawProj, "tracks"] =>
      if req.method == "POST" then
        let some proj := resolveCallerProj rawProj
          | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        recordCallerProj proj
        let track := (jv.fieldStr? "track").getD ""
        let desired := (jv.fieldStr? "desired_condition").getD ""
        let status := (jv.fieldStr? "status").getD "open"
        let expRev? := jv.fieldNat? "expected_revision"
        let (code, body) ← putProjectTrack st.store proj track desired status s!"{nowEpochSec}" expRev?
        return .ok (mkJson code body)
    | [rawProj, "board"] =>
      if req.method == "GET" then
        let some proj := resolveCallerProj rawProj
          | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
        match ← projectBoardJson st.store proj with
        | .ok body => return .ok (mkJson 200 body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    | rawProj :: "context" :: restSegs =>
      let some proj := resolveCallerProj rawProj
        | return .ok (mkJson 400 "{\"error\":\"invalid_project\"}")
      let rest := String.intercalate "/" restSegs
      let (kind, arg) := splitContextSuffix rest
      if kind == "manifest" && req.method == "GET" && arg.isEmpty then
        match ← contextManifestJson st.store proj with
        | .ok body => return .ok (mkJson 200 body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "conflicts" && req.method == "GET" && arg.isEmpty then
        match ← contextConflictsJson st.store proj with
        | .ok body => return .ok (mkJson 200 body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "conflicts" && req.method == "POST" && !arg.isEmpty then
        let some cid := percentDecodeStrict arg
          | return .ok (mkJson 400 "{\"error\":\"invalid_conflict_id\"}")
        if cid.isEmpty then
          return .ok (mkJson 400 "{\"error\":\"invalid_conflict_id\"}")
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        recordCallerProj proj
        match ← applyContextOperation st.store st.store.rootDir proj jv s!"{nowEpochSec}" (some cid) with
        | .ok (code, body) => return .ok (mkJson code body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "history" && req.method == "GET" && arg.isEmpty then
        match ← contextHistoryJson st.store proj with
        | .ok body => return .ok (mkJson 200 body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "stream" && req.method == "GET" && arg.isEmpty then
        match ← contextStreamEvent st.store proj with
        | .ok ev =>
          return .ok {
            status := 200,
            contentType := "text/event-stream",
            corsOrigin? := reqOrigin?,
            extraHdrs := #[("Cache-Control", "no-cache"), ("X-Accel-Buffering", "no")],
            body := ev.toUTF8
          }
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "blobs" && req.method == "POST" && arg.isEmpty then
        let qParams := parseQueryParams rawTarget
        let confirmedLarge :=
          ((qParams.find? (fun p => p.1 == "confirmed_large")).map Prod.snd |>.getD "") == "true" ||
          ((lookupHeaderCI req.headers "x-orb-confirmed-large").getD "") == "1"
        recordCallerProj proj
        match ← putContextBlob st.store.rootDir proj req.bodySlice.toByteArray confirmedLarge with
        | .ok hash => return .ok (mkJson 200 s!"\{\"hash\":{jsonEscape hash}}")
        | .error "oversize" => return .ok (mkJson 413 "{\"error\":\"blob_too_large\"}")
        | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "blobs" && req.method == "GET" && !arg.isEmpty then
        match ← readContextBlob st.store.rootDir proj arg with
        | .ok bytes =>
          return .ok { status := 200, contentType := "application/octet-stream", corsOrigin? := reqOrigin?, body := bytes }
        | .error "blob not found" => return .ok (mkJson 404 "{\"error\":\"blob_not_found\"}")
        | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
      else if kind == "operations" && req.method == "POST" && arg.isEmpty then
        let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
          | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
        recordCallerProj proj
        match ← applyContextOperation st.store st.store.rootDir proj jv s!"{nowEpochSec}" with
        | .ok (code, body) => return .ok (mkJson code body)
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    | _ => pure ()

  -- Guarded System Deploy (`POST /api/system/deploy`, `SM-22` / `G-ORB-7`)
  if cleanPath == "/api/system/deploy" && req.method == "POST" then
    if !caller.isLegacyUnscoped then
      if let some (cCode, cBody) := requireAdminPrincipal caller then
        return .ok (mkJson cCode cBody)
    let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
      | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
    let rawUnit :=
      match jv.fieldStr? "service" with
      | some s => s
      | none => (jv.fieldStr? "expected_service").getD "sandboxed-sh"
    let .ok unitName := validateDeployServiceUnit rawUnit
      | return .ok (mkJson 400 "{\"error\":\"invalid_deploy_unit\"}")
    let dryRun := (jv.fieldBool? "dry_run").getD false
    let forceFlag := (jv.fieldBool? "force").getD false
    let _skipBuild := (jv.fieldBool? "skip_build").getD false
    let _repoPath := (jv.fieldStr? "repo_path").getD ""
    let _callingMissionId := (jv.fieldStr? "calling_mission_id").getD ""
    let _gitRef := (jv.fieldStr? "git_ref").getD ""
    let bodyLease := (jv.fieldStr? "lease_token").getD ""
    let hdrLease := (lookupHeaderCI req.headers "x-orb-lease").getD ""
    let leaseTok := if !bodyLease.isEmpty then bodyLease else hdrLease
    if leaseTok.isEmpty then
      return .ok (mkJson 403 "{\"error\":\"lease_required\"}")
    let some lease ← lookupPrivilegeLease? st.store leaseTok
      | return .ok (mkJson 403 "{\"error\":\"unknown_lease\"}")
    let nowLive ← coreEpochSec
    let memBunker ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
    let obs ← observeDeployLive st.store unitName forceFlag dryRun false (some lease) nowLive memBunker
    let reobserve : IO DeployObservation := do
      let liveSec ← coreEpochSec
      let liveMem ← match st.bunkerStateRef? with | some r => r.get | none => pure (0 : UInt8)
      let liveLease? ← lookupPrivilegeLease? st.store leaseTok
      observeDeployLive st.store unitName forceFlag dryRun false liveLease? liveSec liveMem
    match ← runGuardedDeploy st.store obs reobserve dryRun s!"{nowLive}" none with
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    | .ok rcpt =>
      let code := if rcpt.verdict == "admitted" || rcpt.verdict == "dry_run_admitted" then 200 else 409
      return .ok (mkJson code s!"\{\"unit\":{jsonEscape rcpt.unitName},\"verdict\":{jsonEscape rcpt.verdict},\"verdict_code\":{rcpt.verdictCode},\"dry_run\":{if rcpt.dryRun then "true" else "false"}}")

  -- Multi-User Opt-In Usage Telemetry (`/api/usage-telemetry`, `/api/usage-telemetry/config`, `/api/usage-telemetry/events`)
  if cleanPath == "/api/usage-telemetry" || cleanPath.startsWith "/api/usage-telemetry/" then
    let tSink ← match st.telemetrySink? with
      | some s => pure s
      | none => newTelemetrySink
    if cleanPath == "/api/usage-telemetry" && req.method == "GET" then
      let s ← loadTelemetrySettings st.store.rootDir
      let body ← renderTelemetryStatusJson s tSink
      return .ok (mkJson 200 body)
    else if cleanPath == "/api/usage-telemetry/config" && req.method == "PUT" then
      if !caller.isLegacyUnscoped then
        if let some (cCode, cBody) := requireAdminPrincipal caller then
          return .ok (mkJson cCode cBody)
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let mut s ← loadTelemetrySettings st.store.rootDir
      if let some en := jv.fieldBool? "enabled" then
        s := { s with enabled := en }
      if let some pr := jv.fieldBool? "prompts_enabled" then
        s := { s with promptsEnabled := pr }
      if let some rawUrl := jv.fieldStr? "hub_url" then
        let u := stripTrailingSlash rawUrl.trimAscii.toString
        if !u.isEmpty && !hubUrlAllowed u then
          return .ok (mkJson 400 "{\"error\":\"hub_url must be https (http only on loopback)\"}")
        let nextUrl := if u.isEmpty then defaultHubUrl else u
        if nextUrl != s.hubUrl && (jv.fieldStr? "token").isNone then
          s := { s with encryptedToken := none }
        s := { s with hubUrl := nextUrl }
      if let some rawNs := jv.fieldStr? "namespace" then
        let ns := rawNs.trimAscii.toString
        if !ns.isEmpty && !validTelemetryNamespace ns then
          return .ok (mkJson 400 "{\"error\":\"namespace must be [a-z0-9_-]{1,40} and not community\"}")
        s := { s with ns := if ns.isEmpty then none else some ns }
      if let some rawTok := jv.fieldStr? "token" then
        let tok := rawTok.trimAscii.toString
        if tok.isEmpty then
          s := { s with encryptedToken := none }
        else
          match ← encryptTelemetryToken (effectiveJwtSecret st.cfg) st.store.rootDir tok with
          | .error _ => return .ok (mkJson 500 "{\"error\":\"Failed to encrypt telemetry token\"}")
          | .ok enc => s := { s with encryptedToken := some enc }
      if s.promptsEnabled && !s.enabled then
        s := { s with promptsEnabled := false }
      if let .error e ← saveTelemetrySettings st.store.rootDir s then
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      let tgt? ← resolveHubTarget (effectiveJwtSecret st.cfg) st.store.rootDir s
      syncSinkTarget tSink tgt?
      let body ← renderTelemetryStatusJson s tSink
      return .ok (mkJson 200 body)
    else if cleanPath == "/api/usage-telemetry/events" && req.method == "POST" then
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let some evArr := jv.fieldArr? "events"
        | return .ok (mkJson 400 "{\"error\":\"missing_events_array\"}")
      let actorUid? := if caller.isLegacyUnscoped || caller.userId.isEmpty then none else some caller.userId
      let actorUname? := if caller.isLegacyUnscoped || caller.username.isEmpty then none else some caller.username
      let (enabled, accepted) ← acceptClientTelemetryBatch tSink evArr actorUid? actorUname? nowEpochSec
      if enabled && accepted > 0 then
        let qLen ← tSink.mu.atomically do return (← get).events.size
        if qLen ≥ telemetryBatchSize then
          discard <| IO.asTask (prio := .dedicated) (do discard <| flushTelemetryOnce tSink nowEpochSec)
      return .ok (mkJson 202 s!"\{\"enabled\":{if enabled then "true" else "false"},\"accepted\":{accepted}}")

  -- Authenticated Speaker-Attributed Voice Transcription Relay (`POST /api/voice/transcribe?language=<lang>`)
  if cleanPath == "/api/voice/transcribe" && req.method == "POST" then
    let qParams := parseQueryParams rawTarget
    let lang := ((qParams.find? (fun p => p.1 == "language")).map Prod.snd |>.getD "").trimAscii.toString
    if lang.isEmpty then
      return .ok (mkJson 400 "{\"error\":\"Missing language query parameter.\"}")
    let vSlots ← match st.voiceSlots? with
      | some vs => pure vs
      | none => newVoiceRelaySlots
    let (vCode, vBody) ← transcribeVoiceRelay
      vSlots lang req.bodySlice.toByteArray caller.userId caller.username caller.isLegacyUnscoped st.voiceEndpointOverride?
    return .ok (mkJson vCode vBody)

  -- Settings, Proxy API Keys, Capabilities & Stats Parity Endpoints
  if cleanPath == "/api/settings" && (req.method == "GET" || req.method == "PUT" || req.method == "PATCH") then
    let isAdm := caller.isLegacyUnscoped || caller.role == "admin"
    if !isAdm then
      return .ok (mkJson 403 "{\"error\":\"admin_required\"}")
    if req.method == "GET" then
      let rawSettings ← readSettingsJson st.store.rootDir
      return .ok (mkJson 200 (renderCompact (redactSettingsSecrets rawSettings)))
    else
      let .ok patchJv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let curSettings ← readSettingsJson st.store.rootDir
      let merged :=
        match curSettings, patchJv with
        | .obj basePairs, .obj patchPairs =>
          Id.run do
            let mut acc := JVal.obj basePairs
            for (k, v) in patchPairs do
              -- `bitwarden` is owned by `/api/bitwarden/*`; a redacted copy sent back here must not erase the token.
              if k != "password_hash" && k != "bitwarden" && k != "bws_access_token" then
                acc := acc.setField k v
            return acc
        | _, _ => curSettings
      if let .error e ← writeSettingsJson st.store.rootDir merged then
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      return .ok (mkJson 200 (renderCompact (redactSettingsSecrets merged)))

  if cleanPath == "/api/proxy-keys" || cleanPath.startsWith "/api/proxy-keys/" then
    let isAdm := caller.isLegacyUnscoped || caller.role == "admin"
    if !isAdm then
      return .ok (mkJson 403 "{\"error\":\"admin_required\"}")
    if req.method == "GET" && cleanPath == "/api/proxy-keys" then
      return .ok (mkJson 200 (← listProxyApiKeysJson st.store.rootDir))
    else if req.method == "POST" && cleanPath == "/api/proxy-keys" then
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let nm := (jv.fieldStr? "name").getD "Proxy Key"
      match ← createProxyApiKeyJson st.store.rootDir nm (formatEpochIso8601Utc nowEpochSec) with
      | .ok out => return .ok (mkJson 201 out)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "DELETE" && cleanPath.startsWith "/api/proxy-keys/" then
      let kid := (cleanPath.drop 16).toString
      let deleted ← deleteProxyApiKey st.store.rootDir kid
      if deleted then return .ok (mkJson 200 "{\"ok\":true}")
      else return .ok (mkJson 404 "{\"error\":\"not_found\"}")

  if req.method == "GET" && cleanPath == "/api/capabilities" then
    return .ok (mkJson 200 "{\"mission_moves\":true,\"project_folders\":true,\"mcp_gateway\":true,\"managed_relay\":true}")

  if req.method == "GET" && cleanPath == "/api/stats" then
    let mCnt ← match ← execParamQuery st.store.missionsDb "SELECT COUNT(*) FROM missions;" #[] with
      | .ok rs => pure (((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0)
      | .error _ => pure 0
    return .ok (mkJson 200 s!"\{\"missions\":{mCnt}}")

  let isAdmCaller := caller.isLegacyUnscoped || caller.role == "admin"
  let nowIsoDisp := formatEpochIso8601Utc nowEpochSec

  if let some (sCode, sCtype, sBody) ← dispatchSecretAndApprovalRoutes?
      st.store st.cfg.workingDir st.store.rootDir st.bunkerStateRef? isAdmCaller
      req.method rawTarget cleanPath req.bodySlice.toByteArray nowEpochSec then
    return .ok { status := sCode, contentType := sCtype, corsOrigin? := reqOrigin?, body := sBody.toUTF8 }

  if let some mst := st.managedStore? then
    if let some (rCode, rCtype, rBody) ← dispatchRemoteFleetAndRelayRoutes?
        st.store mst st.relayHub? (← st.managedRef.get)
        req.method cleanPath rawTarget req.headers req.bodySlice.toByteArray
        caller.userId isAdmCaller caller.isLegacyUnscoped nowEpochSec nowIsoDisp st.managedProvisioningOverride? then
      return .ok { status := rCode, contentType := rCtype, corsOrigin? := reqOrigin?, body := rBody }

  if let some (pCode, pCtype, pBody) ← dispatchProjectAndControllerRoutes?
      st.store st.broadcastHub? st.cfg.workingDir
      req.method cleanPath rawTarget req.bodySlice.toByteArray
      caller.userId st.bootstrapAdminId isAdmCaller caller.isLegacyUnscoped nowIsoDisp then
    return .ok { status := pCode, contentType := pCtype, corsOrigin? := reqOrigin?, body := pBody }

  let cHubFallback ← match st.cloudHub? with | some h => pure h | none => newCloudRuntimeHub
  if let some (cCode, cCtype, cBody) ← dispatchCloudHttpRoute
      cHubFallback st.store st.broadcastHub? st.cfg.port
      req.method cleanPath rawTarget req.bodySlice.toByteArray
      caller.userId caller.username st.bootstrapAdminId isAdmCaller caller.isLegacyUnscoped then
    return .ok { status := cCode, contentType := cCtype, corsOrigin? := reqOrigin?, body := cBody }

  let sHubFallback ← match st.systemHub? with | some h => pure h | none => newSystemRuntimeHub
  if let some (sysCode, sysCtype, sysBody) ← dispatchResourcesAndSystemRoute
      sHubFallback st.store st.cfg.workingDir st.cfg.libraryRemote st.cfg.githubClientId
      st.bunkerStateRef? st.managedStore? st.relayHub? st.broadcastHub?
      req.method cleanPath rawTarget req.headers req.bodySlice.toByteArray
      caller.userId caller.username st.bootstrapAdminId isAdmCaller caller.isLegacyUnscoped then
    return .ok { status := sysCode, contentType := sysCtype, corsOrigin? := reqOrigin?, body := sysBody }

  return .ok (mkJson 404 s!"\{\"error\":\"not_found\",\"path\":{jsonEscape cleanPath}}")

/-- Dispatch a parsed `HttpRequest` against `CoreAppState` (`routes` capability parity:
    `"/api/control/missions/:id/automations"`, `"/api/model-routing"`), emitting authorized
    `mission_presentation` notices on `2xx` control mutations and applying RFC 1952 `gzip`
    content encoding when requested via `Accept-Encoding: gzip` on bodies `>= 1 KiB`. -/
def dispatchCoreRequest (st : CoreAppState) (req : HttpRequest) (nowEpochSec : UInt64) : IO (Except ByteArray CoreHttpResponse) := do
  let hasListeners ← match st.store.eventListenersRef? with
    | some ref => pure (!(← ref.get).isEmpty)
    | none => pure false
  let mut preDeleteMeta? : Option (String × String × Array String × Option String) := none
  if hasListeners && req.method == "DELETE" then
    if let some params := matchRoutePattern? "/api/control/missions/:id" req.path then
      let rawMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let mid := (percentDecodeStrict rawMid).getD rawMid
      if !mid.isEmpty then
        let mut ownerUid := ""
        let mut btwParent? : Option String := none
        if let .ok mRs ← execParamQuery st.store.missionsDb
            "SELECT COALESCE(owner_user_id,''), COALESCE(tags,'[]') FROM missions WHERE id=?1;" #[mid] then
          if mRs.size > 1 then
            ownerUid := (mRs[1]![0]?).getD ""
            btwParent? := extractBtwParentIdFromTagsJson? ((mRs[1]![1]?).getD "[]")
        let mut sharedUids : Array String := #[]
        if let .ok sRs ← execParamQuery st.store.missionsDb
            "SELECT user_id FROM mission_shares WHERE mission_id=?1;" #[mid] then
          for i in [1:sRs.size] do
            let uid := (sRs[i]![0]?).getD ""
            if !uid.isEmpty then sharedUids := sharedUids.push uid
        preDeleteMeta? := some (mid, ownerUid, sharedUids, btwParent?)
  match ← dispatchCoreRequestRaw st req nowEpochSec with
  | .ok resp =>
    if hasListeners && req.method != "GET" && req.method != "HEAD" && req.method != "OPTIONS" &&
       resp.status ≥ 200 && resp.status < 300 then
      let cleanPath := (req.path.splitOn "?").headD req.path
      if let some (delMid, ownerUid, sharedUids, btwParent?) := preDeleteMeta? then
        emitMissionPresentationNotice st.store delMid "mission_deleted"
          (if ownerUid.isEmpty then none else some ownerUid) sharedUids btwParent?
      else if cleanPath == "/api/control/missions" then
        if let .ok jv := OrbBin.Json.parseBytes resp.body then
          if let some mid := (jv.fieldStr? "id").filter (!·.isEmpty) then
            emitMissionPresentationNotice st.store mid "mission_created"
      else if cleanPath == "/api/control/message" then
        if let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray then
          if let some mid := (jv.fieldStr? "mission_id").filter (!·.isEmpty) then
            emitMissionPresentationNotice st.store mid "user_message"
      else if cleanPath.startsWith "/api/control/missions/" then
        let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
        if segs.length ≥ 4 then
          let rawMid := segs[3]!
          let mid := (percentDecodeStrict rawMid).getD rawMid
          let sub := segs.drop 4
          let isCollectionAction :=
            segs.length == 4 && (mid == "reconcile" || mid == "reconcile-pending" || mid == "search")
          let isBtwContextOnly := sub == ["btw", "context"]
          if !mid.isEmpty && !isCollectionAction && !isBtwContextOnly then
            let kind :=
              if sub == ["settings"] || sub == ["cyber"] || sub == ["permission-mode"] || sub == ["budget"] then
                "mission_settings_updated"
              else if sub == ["stop"] || sub == ["cancel"] || sub == ["interrupt"] || sub == ["resume"] ||
                      sub == ["rate-limit", "park"] || sub == ["rate-limit", "resume"] then
                "mission_status_changed"
              else
                "mission_updated"
            emitMissionPresentationNotice st.store mid kind
            if sub == ["btw", "agent"] || sub == ["fork"] then
              if let .ok jv := OrbBin.Json.parseBytes resp.body then
                if let some childId := (jv.fieldStr? "id").filter (fun s => !s.isEmpty && s != mid) then
                  emitMissionPresentationNotice st.store childId "mission_created" none #[] (some mid)
      else if cleanPath.startsWith "/api/control/automations/" ||
              cleanPath == "/api/control/queue" ||
              cleanPath.startsWith "/api/control/queue/" then
        let respMid? : Option String :=
          match OrbBin.Json.parseBytes resp.body with
          | .ok jv => (jv.fieldStr? "mission_id").filter (fun (s : String) => !s.isEmpty)
          | .error _ => none
        let effMid? : Option String :=
          match respMid? with
          | some m => some m
          | none =>
            match OrbBin.Json.parseBytes req.bodySlice.toByteArray with
            | .ok jv => (jv.fieldStr? "mission_id").filter (fun (s : String) => !s.isEmpty)
            | .error _ => none
        if let some mid := effMid? then
          emitMissionPresentationNotice st.store mid "mission_updated"
    return .ok (maybeGzipHttpResponse req resp)
  | .error raw101 => return .error raw101

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

/-- Per-mission subscription entry on `/api/control/sync`, buffering concurrent live events
    while `replaying == true` so replay frames always precede live frames in strict `seq` order. -/
private structure SyncMissionSubState where
  maxPayload : Nat
  replaying  : Bool := false
  queuedLive : Array (UInt64 × String) := #[]

private structure SyncWsOutboundState where
  frames   : Array ByteArray := #[]
  bytes    : Nat := 0
  draining : Bool := false
  closed   : Bool := false
  overflow : Bool := false
  revoked  : Bool := false

/-- Multiplexed `/api/control/sync` WebSocket session (`orb-sync.v1`):
    supports `ping`/`pong`, `set_presentation`, `subscribe` (`since_seq` replay + `sync_caught_up`),
    `unsubscribe`, `sync_resume`, live `appendMissionEvent` push, and compact `inbox_answer_push`.
    Outbound frames are queued into a bounded per-session ring (`512` frames / `2 MiB`) and flushed
    asynchronously over a non-blocking socket so a slow or wedged client never blocks the store
    dispatcher or other sessions. -/
def runSyncWebSocketSessionLoop
    (st : CoreAppState)
    (wsCaller : CallerPrincipal)
    (cfd : Fd)
    (maxSteps? : Option Nat := none)
    (reqHdrs : Array (String × String) := #[]) : IO Unit := do
  discard <| setNonBlocking cfd true
  let subMu ← Std.Mutex.new ({} : Std.HashMap String SyncMissionSubState)
  let outMu ← Std.Mutex.new ({} : SyncWsOutboundState)
  let writeMu ← Std.Mutex.new ()
  let aliveRef ← IO.mkRef true
  let presRef ← IO.mkRef false
  let activeWriterRef ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
  let maxOutFrames : Nat := 512
  let maxOutBytes : Nat := 2 * 1024 * 1024
  let writeWsBounded (wire : ByteArray) (maxWaitSlices : Nat := 40) (ignoreAlive : Bool := false) : IO Bool := do
    writeMu.atomically do
      let mut off : Nat := 0
      let mut waits : Nat := 0
      let mut failed := false
      while off < wire.size && !failed do
        if !ignoreAlive && !(← aliveRef.get) then
          failed := true
        else
          match ← writeSlicePartial cfd { ba := wire, off := off, len := wire.size - off } with
          | .ok n =>
            if n == 0 then
              failed := true
            else
              off := off + n
              waits := 0
          | .error .eagain =>
            if waits >= maxWaitSlices then
              failed := true
            else
              waits := waits + 1
              discard <| pollFdSet #[cfd] 50 1
          | .error _ =>
            failed := true
      if failed then
        aliveRef.set false
        return false
      return true
  let popOutBatch : IO (Array ByteArray × Bool × Bool) :=
    outMu.atomically do
      let s ← get
      if s.frames.isEmpty && !s.overflow && !s.revoked then
        set { s with draining := false }
        return (#[], false, false)
      else
        let b := s.frames
        let ov := s.overflow
        let rv := s.revoked
        set { s with frames := #[], bytes := 0, overflow := false, revoked := false, draining := true }
        return (b, ov, rv)
  let markOutFinished (closeSession : Bool) : IO Unit :=
    outMu.atomically do
      modify fun s =>
        if closeSession then
          { s with frames := #[], bytes := 0, draining := false, closed := true, overflow := false, revoked := false }
        else
          { s with draining := false }
  let startDrainTask : IO Unit := do
    let t ← IO.asTask do
      let mut running := true
      while running do
        let (batch, didOverflow, didRevoke) ← popOutBatch
        if batch.isEmpty && !didOverflow && !didRevoke then
          running := false
        else
          let mut ok := true
          for wire in batch do
            if ok then
              ok ← writeWsBounded wire 40 false
          if didRevoke then
            if let some clsFrm := makeServerClose? 1008 "unauthorized" then
              discard <| writeWsBounded clsFrm 2 true
            aliveRef.set false
            markOutFinished true
            running := false
          else if didOverflow then
            if ok then
              if let some lagFrm := encodeFrame? { fin := true, opcode := .text, payload := "{\"type\":\"stream_lagged\"}".toUTF8 } none then
                discard <| writeWsBounded lagFrm 2 true
              if let some clsFrm := makeServerClose? 1008 "stream_lagged" then
                discard <| writeWsBounded clsFrm 2 true
            aliveRef.set false
            markOutFinished true
            running := false
          else if !ok then
            markOutFinished true
            running := false
    activeWriterRef.set (some t)
  let revokeSession : IO Unit := do
    aliveRef.set false
    presRef.set false
    subMu.atomically do set ({} : Std.HashMap String SyncMissionSubState)
    let shouldSpawn ← outMu.atomically do
      let s ← get
      let sp := !s.draining
      set { s with frames := #[], bytes := 0, draining := true, closed := true, revoked := true }
      return sp
    if shouldSpawn then
      startDrainTask
  let sendWsBytes (wire : ByteArray) : IO Bool := do
    if !(← aliveRef.get) then
      return false
    let res ← outMu.atomically do
      let s ← get
      if s.closed || s.overflow then
        return (false, false)
      else if s.frames.size ≥ maxOutFrames || s.bytes + wire.size > maxOutBytes then
        let shouldSpawn := !s.draining
        set { s with frames := #[], bytes := 0, draining := true, closed := true, overflow := true }
        return (false, shouldSpawn)
      else
        let shouldSpawn := !s.draining
        set { s with frames := s.frames.push wire, bytes := s.bytes + wire.size, draining := true }
        return (true, shouldSpawn)
    if !res.1 then
      aliveRef.set false
      if res.2 then
        startDrainTask
      return false
    if res.2 then
      startDrainTask
    return true
  let sendWsText (txt : String) : IO Bool := do
    match encodeFrame? { fin := true, opcode := .text, payload := txt.toUTF8 } none with
    | none => return false
    | some frm => sendWsBytes frm
  let liveSyncCaller? : IO (Option CallerPrincipal) := do
    if !(← aliveRef.get) then return none
    let resolved? ←
      if !reqHdrs.isEmpty then
        resolveCallerPrincipal? st reqHdrs (← coreEpochSec) (allowWsSubproto := true)
      else if wsCaller.isLegacyUnscoped then
        pure (some wsCaller)
      else
        match ← getUserById? st.store wsCaller.userId with
        | none => pure none
        | some u =>
          let epochMatch : UInt8 := if u.sessionEpoch == wsCaller.sessionEpoch then 1 else 0
          let disFlag : UInt8 := if u.disabled then 1 else 0
          let roleCode : UInt8 := if u.role == "admin" then 1 else 0
          let rbacWord := Orb.Kernel.multiuserRbacStep 1 disFlag epochMatch roleCode 0 1 0
          if (rbacWord &&& 1) == 1 then
            pure (some (CallerPrincipal.ofUserRecord u false))
          else
            pure none
    if resolved?.isNone then
      revokeSession
    return resolved?
  let authorizeAndGetMissionBtwParent? (mid : String) : IO (Bool × Option String) := do
    if mid.isEmpty then return (false, none)
    let some liveCaller ← liveSyncCaller?
      | return (false, none)
    if liveCaller.isLegacyUnscoped then
      match ← execParamQuery st.store.missionsDb "SELECT COALESCE(tags,'[]') FROM missions WHERE id=?1;" #[mid] with
      | .ok rows =>
        let tagsJson := if rows.size > 1 then (rows[1]![0]?).getD "[]" else "[]"
        return (true, extractBtwParentIdFromTagsJson? tagsJson)
      | .error _ => return (true, none)
    else
      match ← execParamQuery st.store.missionsDb
        ("SELECT COALESCE(m.owner_user_id,''), " ++
         "CASE WHEN EXISTS (SELECT 1 FROM mission_shares s WHERE s.mission_id = m.id AND s.user_id = ?2) THEN '1' ELSE '0' END, " ++
         "COALESCE(m.tags,'[]') FROM missions m WHERE m.id = ?1;")
        #[mid, liveCaller.userId] with
      | .error _ => return (false, none)
      | .ok rows =>
        if rows.size ≤ 1 then return (false, none)
        let ownerId := (rows[1]![0]?).getD ""
        let isOwner := !liveCaller.userId.isEmpty && ownerId == liveCaller.userId
        let isPart := ((rows[1]![1]?).getD "0") == "1"
        let tagsJson := (rows[1]![2]?).getD "[]"
        let disFlag : UInt8 := if liveCaller.disabled then 1 else 0
        let roleCode : UInt8 := if liveCaller.role == "admin" then 1 else 0
        let rbacWord := Orb.Kernel.multiuserRbacStep
          1 disFlag 1 roleCode 2 (if isOwner then 1 else 0) (if isPart then 1 else 0)
        if (rbacWord &&& 1) == 1 then
          return (true, extractBtwParentIdFromTagsJson? tagsJson)
        else
          return (false, none)
  let isAuthorizedForMission (mid : String) : IO Bool := do
    return (← authorizeAndGetMissionBtwParent? mid).1
  let renderSyncPresentationJson (mid kind : String) (label? btwParent? : Option String) : String := Id.run do
    let mut fields : Array String := #[
      "\"type\":\"mission_presentation\"",
      s!"\"mission_id\":{jsonEscape mid}",
      s!"\"kind\":{jsonEscape kind}"
    ]
    if let some lbl := label? then
      fields := fields.push s!"\"label\":{jsonEscape lbl}"
    if let some bp := btwParent? then
      if !bp.isEmpty then
        fields := fields.push s!"\"btw_parent_id\":{jsonEscape bp}"
    return "{" ++ String.intercalate "," fields.toList ++ "}"
  let unregister ← registerMissionEventListener st.store fun mid seq evType payloadJson createdAt => do
    if (← aliveRef.get) then
      if evType != "__presentation__" then
        let hasSub ← subMu.atomically do return (← get).contains mid
        if hasSub then
          let isAuth ← isAuthorizedForMission mid
          if !isAuth then
            let removed ← subMu.atomically do
              let m ← get
              if m.contains mid then
                set (m.erase mid)
                return true
              else
                return false
            if removed && (← aliveRef.get) then
              discard <| sendWsText s!"\{\"type\":\"unsubscribed\",\"mission_id\":{jsonEscape mid},\"error\":\"forbidden\"}"
          else
            subMu.atomically do
              let m ← get
              if let some sub := m[mid]? then
                let frameJson := renderSyncWsEventJson mid seq evType payloadJson createdAt (some sub.maxPayload) false
                if sub.replaying then
                  set (m.insert mid { sub with queuedLive := sub.queuedLive.push (seq, frameJson) })
                else
                  discard <| sendWsText frameJson
        else if (evType == "assistant_message" || evType == "assistant_message_canonical") && payloadJson.utf8ByteSize ≤ 8192 then
          if ← isAuthorizedForMission mid then
            discard <| sendWsText (renderSyncWsEventJson mid seq evType payloadJson createdAt (some 4096) true)
      if ← presRef.get then
        if evType == "__presentation__" then
          let jv := (OrbBin.Json.parse payloadJson).toOption.getD (.obj #[])
          let kind := (jv.fieldStr? "kind").getD "mission_updated"
          let hintBtw? := (jv.fieldStr? "btw_parent_id").filter (!·.isEmpty)
          if kind == "mission_deleted" then
            if let some liveCaller ← liveSyncCaller? then
              let ownerUid := (jv.fieldStr? "owner_uid").getD ""
              let sharedUids : Array String :=
                match jv.fieldArr? "shared_uids" with
                | some xs => xs.filterMap JVal.asStr?
                | none => #[]
              let allowed : Bool :=
                if liveCaller.isLegacyUnscoped then true
                else
                  let isOwner := !liveCaller.userId.isEmpty && ownerUid == liveCaller.userId
                  let isPart := !liveCaller.userId.isEmpty && sharedUids.contains liveCaller.userId
                  let disFlag : UInt8 := if liveCaller.disabled then 1 else 0
                  let roleCode : UInt8 := if liveCaller.role == "admin" then 1 else 0
                  let rbacWord := Orb.Kernel.multiuserRbacStep
                    1 disFlag 1 roleCode 2 (if isOwner then 1 else 0) (if isPart then 1 else 0)
                  (rbacWord &&& 1) == 1
              if allowed then
                discard <| sendWsText (renderSyncPresentationJson mid kind none hintBtw?)
          else
            let (isAuth, dbBtw?) ← authorizeAndGetMissionBtwParent? mid
            if isAuth then
              let effBtw? : Option String := match hintBtw? with | some b => some b | none => dbBtw?
              discard <| sendWsText (renderSyncPresentationJson mid kind none effBtw?)
        else if evType == "tool_call" || evType == "thinking" then
          let (isAuth, dbBtw?) ← authorizeAndGetMissionBtwParent? mid
          if isAuth then
            let lbl := (deriveEventActivityLabel? evType payloadJson).getD (if evType == "thinking" then "Thinking…" else "Working…")
            discard <| sendWsText (renderSyncPresentationJson mid "mission_activity" (some lbl) dbBtw?)
        else if evType == "user_message" || evType == "assistant_message" ||
                evType == "assistant_message_canonical" || evType == "mission_status_changed" ||
                evType == "mission_settings_updated" || evType == "error" then
          let (isAuth, dbBtw?) ← authorizeAndGetMissionBtwParent? mid
          if isAuth then
            discard <| sendWsText (renderSyncPresentationJson mid evType none dbBtw?)
  try
    discard <| sendWsText "{\"type\":\"sync_ready\",\"server\":\"sandboxed-sh\",\"server_build\":\"orb-core-lean\"}"
    let replayForMission (mid : String) (sinceSeq? : Option UInt64) (maxP : Nat) : IO Unit := do
      let repRes ← queryMissionSyncReplayFrames st.store mid sinceSeq? (some maxP) 500
      let stillAuth ← isAuthorizedForMission mid
      if !stillAuth then
        subMu.atomically do modify (·.erase mid)
        if ← aliveRef.get then
          discard <| sendWsText s!"\{\"type\":\"unsubscribed\",\"mission_id\":{jsonEscape mid},\"error\":\"forbidden\"}"
      else
        match repRes with
        | .error _ =>
          subMu.atomically do
            let m ← get
            if m.contains mid then
              set (m.insert mid { maxPayload := maxP, replaying := false, queuedLive := #[] })
          discard <| sendWsText s!"\{\"type\":\"stream_lagged\",\"mission_id\":{jsonEscape mid}}"
        | .ok (frames, curSeq, lagged) =>
          subMu.atomically do
            let m ← get
            if let some sub := m[mid]? then
              if lagged then
                set (m.insert mid { sub with replaying := false, queuedLive := #[] })
                discard <| sendWsText s!"\{\"type\":\"stream_lagged\",\"mission_id\":{jsonEscape mid}}"
              else
                for f in frames do
                  discard <| sendWsText f
                let mut finalSeq := curSeq
                let mut sentCount := frames.size
                for (qSeq, qFrame) in sub.queuedLive do
                  if qSeq == 0 || qSeq > finalSeq then
                    if qSeq > finalSeq then finalSeq := qSeq
                    sentCount := sentCount + 1
                    discard <| sendWsText qFrame
                set (m.insert mid { sub with replaying := false, queuedLive := #[] })
                discard <| sendWsText s!"\{\"type\":\"sync_caught_up\",\"mission_id\":{jsonEscape mid},\"cursor\":{finalSeq},\"replayed\":{sentCount}}"
    let mut rxBuf := ByteArray.empty
    let mut steps : Nat := 0
    let mut loopOpen := true
    let pollMs : UInt32 := if maxSteps?.isSome then 2000 else 15000
    while loopOpen && (← aliveRef.get) && (match maxSteps? with | some lim => decide (steps < lim) | none => true) do
      steps := steps + 1
      match ← pollReadable cfd pollMs with
      | .error .eagain =>
        if maxSteps?.isSome then
          loopOpen := false
        else if (← liveSyncCaller?).isSome then
          discard <| sendWsText "{\"type\":\"heartbeat\"}"
        else
          loopOpen := false
      | .error _ =>
        aliveRef.set false
        loopOpen := false
      | .ok () =>
        let chunk ← readStreamChunk cfd 65536
        if chunk.isEmpty then
          aliveRef.set false
          loopOpen := false
        else
          rxBuf := rxBuf ++ chunk
          let mut drainFrames := true
          while drainFrames && loopOpen && (← aliveRef.get) do
            match decodeFramePrefix rxBuf true with
            | .error _ =>
              aliveRef.set false
              loopOpen := false
              drainFrames := false
            | .ok none =>
              drainFrames := false
            | .ok (some (frame, consumed)) =>
              rxBuf := rxBuf.extract consumed rxBuf.size
              match frame.opcode with
              | .ping =>
                if let some pong := makeServerPong? frame.payload then
                  discard <| sendWsBytes pong
              | .close =>
                if let some cls := makeServerClose? 1000 "" then
                  discard <| sendWsBytes cls
                loopOpen := false
                drainFrames := false
              | .text | .binary =>
                if (← liveSyncCaller?).isNone then
                  loopOpen := false
                  drainFrames := false
                else if let some rawStr := String.fromUTF8? frame.payload then
                  if let .ok jv := OrbBin.Json.parse rawStr then
                    let op := (jv.fieldStr? "op").getD ""
                    if op == "ping" then
                      let tsVal := (jv.fieldNat? "ts").getD 0
                      discard <| sendWsText s!"\{\"type\":\"pong\",\"ts\":{tsVal}}"
                    else if op == "set_presentation" then
                      let en := (jv.fieldBool? "enabled").getD false
                      presRef.set en
                      discard <| sendWsText s!"\{\"type\":\"subscribed\",\"presentation\":{if en then "true" else "false"}}"
                    else if op == "unsubscribe" then
                      let mid := (jv.fieldStr? "mission_id").getD ""
                      if !mid.isEmpty then
                        subMu.atomically do modify (·.erase mid)
                        discard <| sendWsText s!"\{\"type\":\"unsubscribed\",\"mission_id\":{jsonEscape mid}}"
                    else if op == "subscribe" then
                      let mid := (jv.fieldStr? "mission_id").getD ""
                      let maxP := max 256 (min 65536 ((jv.fieldNat? "max_payload").getD 4096))
                      let sinceSeq? := (jv.fieldNat? "since_seq").map Nat.toUInt64
                      if !isSafeMissionId mid then
                        discard <| sendWsText s!"\{\"type\":\"unsubscribed\",\"mission_id\":{jsonEscape mid},\"error\":\"invalid_mission_id\"}"
                      else if !(← isAuthorizedForMission mid) then
                        if ← aliveRef.get then
                          discard <| sendWsText s!"\{\"type\":\"unsubscribed\",\"mission_id\":{jsonEscape mid},\"error\":\"forbidden\"}"
                      else
                        subMu.atomically do
                          modify (fun m => m.insert mid { maxPayload := maxP, replaying := true, queuedLive := #[] })
                        replayForMission mid sinceSeq? maxP
                    else if op == "sync_resume" then
                      if let some (.obj pairs) := jv.field? "cursors" then
                        for (mid, curVal) in pairs do
                          if isSafeMissionId mid && (← isAuthorizedForMission mid) then
                            let sinceSeq? : Option UInt64 := curVal.asNat?.map Nat.toUInt64
                            let maxP ← subMu.atomically do
                              let m ← get
                              let mp := (m[mid]?.map (·.maxPayload)).getD 4096
                              set (m.insert mid { maxPayload := mp, replaying := true, queuedLive := #[] })
                              return mp
                            replayForMission mid sinceSeq? maxP
                          else if isSafeMissionId mid then
                            subMu.atomically do modify (·.erase mid)
              | _ => pure ()
    if loopOpen && (← aliveRef.get) then
      if let some cls := makeServerClose? 1000 "" then
        discard <| sendWsBytes cls
  finally
    unregister
    if (← aliveRef.get) then
      let mut flushTicks : Nat := 0
      while flushTicks < 40 && (← outMu.atomically (do return (← get).draining)) do
        IO.sleep 5
        flushTicks := flushTicks + 1
    aliveRef.set false
    outMu.atomically do
      modify fun s => { s with frames := #[], bytes := 0, closed := true }
    let mut stopTicks : Nat := 0
    while stopTicks < 100 && (← outMu.atomically (do return (← get).draining)) do
      IO.sleep 5
      stopTicks := stopTicks + 1
    if let some t ← activeWriterRef.get then
      let _ := t.get

/-- Serve an accepted TCP connection on `cfd`, supporting bounded HTTP/1.1 keep-alive reuse
    when `allowKeepAlive == true` and RFC 6455 WebSocket upgrade (`/api/control/sync` et al.). -/
def handleClientConn (st : CoreAppState) (cfd : Fd) (allowKeepAlive : Bool := false) : IO Unit := do
  let maxReqs : Nat := if allowKeepAlive then 64 else 1
  let mut reqCount : Nat := 0
  let mut carryBuf := ByteArray.empty
  let mut keepGoing := true
  while keepGoing && reqCount < maxReqs do
    let timeoutMs : UInt32 := if reqCount == 0 then 5000 else 15000
    match ← readCoreHttpRequestBuffered cfd carryBuf timeoutMs with
    | .error errMsg =>
      if reqCount == 0 || errMsg != "empty_socket_read" then
        let code := statusForParseError errMsg
        let resp := encodeCoreHttpResponse (jsonResponse code s!"\{\"error\":{jsonEscape errMsg}}") false
        discard <| writeAll cfd resp false
      keepGoing := false
    | .ok (req, leftover) =>
      carryBuf := leftover
      reqCount := reqCount + 1
      let nowSec ← coreEpochSec
      match ← dispatchCoreRequest st req nowSec with
      | .ok httpResp =>
        let wantKeep :=
          allowKeepAlive &&
          reqCount < maxReqs &&
          req.version == "HTTP/1.1" &&
          !headerRequestsClose req.headers
        let wrote := (← writeAll cfd (encodeCoreHttpResponse httpResp wantKeep) false).isOk
        if !wrote || !wantKeep then
          keepGoing := false
      | .error rawUpgrade101 =>
        let wrote := (← writeAll cfd rawUpgrade101 false).isOk
        if wrote then
          let cleanP := (req.path.splitOn "?").headD req.path
          if cleanP == "/api/control/sync" then
            if let some wsCaller ← resolveCallerPrincipal? st req.headers nowSec (allowWsSubproto := true) then
              runSyncWebSocketSessionLoop st wsCaller cfd (if allowKeepAlive then none else some 64) req.headers
          else
            runWebSocketSessionLoop cfd
        keepGoing := false
  discard <| closeFd cfd

/-- Run the blocking HTTP/1.1 + WebSocket listener loop on `cfg.host:cfg.port`. -/
def runCoreServer (cfg : CoreConfig) (maxRequests? : Option Nat := none) : IO UInt32 := do
  match validateRuntimeSecurity cfg with
  | .error msg =>
    IO.eprintln s!"[sandboxed-sh] FATAL security configuration error: {msg}"
    return 1
  | .ok () =>
    let normWork := trimTrailingSlashes cfg.workingDir.trimAscii.toString
    let dataRoot :=
      if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then normWork
      else s!"{normWork}/.sandboxed-sh"
    let store ← match ← openCoreStore dataRoot with
      | .ok s => pure s
      | .error storeErr =>
        IO.eprintln s!"[sandboxed-sh] FATAL: failed to open SQLite CoreStore at {dataRoot}: {storeErr}"
        return 1
    let managedStore ← match ← openManagedComputeStore s!"{dataRoot}/managed_compute.db" with
      | .ok ms => pure ms
      | .error msErr =>
        closeCoreStore store
        IO.eprintln s!"[sandboxed-sh] FATAL: failed to open managed_compute.db at {dataRoot}: {msErr}"
        return 1
    let nowBootSec ← coreEpochSec
    let seedAdmins :=
      let fromUsers := parseConfiguredUsers cfg.usersJson
      if !cfg.dashboardPassword.isEmpty && !fromUsers.any (fun (u, _) => u == "admin") then
        #[("admin", cfg.dashboardPassword)] ++ fromUsers
      else
        fromUsers
    let bootAdminId ←
      match ← bootstrapUsersAndBackfill store seedAdmins s!"{nowBootSec}" with
      | .ok aid => pure aid
      | .error _ => pure ""
    discard <| backfillManagedMachineOwner managedStore bootAdminId
    hydrateLegacyDataDir cfg.workingDir dataRoot store managedStore bootAdminId cfg.devMode
    match ← migrateLegacyLeanciSecret dataRoot with
    | .ok true => IO.eprintln "[sandboxed-sh] sealed lean.ci key moved to its current name"
    | .ok false => pure ()
    | .error e => IO.eprintln s!"[sandboxed-sh] sealed lean.ci key migration failed: {e}"
    let repairedOwners ← repairManagedMachineOwners store managedStore
    if repairedOwners > 0 then
      IO.eprintln s!"[orb-core] repaired the owner of {repairedOwners} pre-cutover managed machine row(s)"
    let effAskTmpRoot : System.FilePath :=
      let fromCfg := cfg.askSandboxTmpRoot.trimAscii.toString
      if !fromCfg.isEmpty then System.FilePath.mk fromCfg else System.FilePath.mk "/tmp"
    let .ok (askPendingNotes, askReapedSandboxes) ← bootstrapAskSidecarOnStartup store.askDb effAskTmpRoot
      | do
        closeManagedComputeStore managedStore
        closeCoreStore store
        IO.eprintln s!"[sandboxed-sh] FATAL: failed to bootstrap Ask sidecar at {dataRoot}"
        return 1
    if askPendingNotes > 0 || !askReapedSandboxes.isEmpty then
      IO.eprintln s!"[sandboxed-sh] Ask sidecar bootstrap: pending_notes={askPendingNotes} reaped_sandboxes={askReapedSandboxes.size}"
    let searchRes ← openSearchIndex s!"{dataRoot}/search_index"
    let boatKeyPresent := (← getBoatApiKey? cfg.workingDir dataRoot).isSome
    let initialManaged :=
      match ← loadManagedFleet managedStore boatKeyPresent boatKeyPresent 2000 0 100 with
      | .ok mf => mf
      | .error _ => ({} : ManagedFleetState)
    let managedRef ← IO.mkRef initialManaged
    let initialChains ← loadRoutingChainsFromStore store cfg.workingDir
    let chainsRef ← IO.mkRef initialChains
    let proxyCooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
    let seqRef ← IO.mkRef (0 : UInt64)
    let healthTracker ← newProviderHealthTracker 1 2
    let authRootDir := s!"{dataRoot}/auth"
    match ← ensurePrivateDir0700 (System.FilePath.mk authRootDir) with
    | .error e =>
      closeManagedComputeStore managedStore
      closeCoreStore store
      IO.eprintln s!"[sandboxed-sh] FATAL: failed to create private auth root `{authRootDir}`: {e}"
      return 1
    | .ok () => pure ()
    let authRotation ← newAuthRotationHandle s!"{authRootDir}/oauth_credentials.json"
    let cliProxySessionsRef ← IO.mkRef (#[] : Array CliProxyLoginSession)
    let memTokenCache ← newMemoryTokenCache
    let cloudWakeup ← newCloudWorkerWakeup
    let bunkerRef ← IO.mkRef (← readPersistedBunkerState store)
    let telemetrySink ← newTelemetrySink
    let initTelSettings ← loadTelemetrySettings store.rootDir
    let initTelTarget? ← resolveHubTarget (effectiveJwtSecret cfg) store.rootDir initTelSettings
    syncSinkTarget telemetrySink initTelTarget?
    let voiceSlots ← newVoiceRelaySlots
    let warmMgr ← OrbBin.ClaudeControl.newWarmHarnessManager
    let pendingControlCallsRef ← IO.mkRef (#[] : Array (String × String))
    let broadcastHub ← newBroadcastHub
    let relayHub ← newRelayHub (if maxRequests?.isSome then 0 else 25000)
    let cloudHub ← newCloudRuntimeHub
    let providerHub ← newProviderRuntimeHub
    let systemHub ← newSystemRuntimeHub
    let remoteSup ← newRemoteJobSupervisor (effectiveJwtSecret cfg) cfg.devMode
    let appState : CoreAppState := {
      cfg := cfg
      store := store
      searchIdx? := searchRes.toOption
      managedRef := managedRef
      chainsRef := chainsRef
      proxyCooldownsRef := proxyCooldownsRef
      seqRef := seqRef
      pacingTracker? := some healthTracker.pacing
      healthTracker? := some healthTracker
      authRoot := authRootDir
      authRotation? := some authRotation
      cliProxySessionsRef? := some cliProxySessionsRef
      memTokenCache? := some memTokenCache
      cloudWakeup? := some cloudWakeup
      bunkerStateRef? := some bunkerRef
      managedStore? := some managedStore
      bootstrapAdminId := bootAdminId
      telemetrySink? := some telemetrySink
      voiceSlots? := some voiceSlots
      warmMgr? := some warmMgr
      pendingControlCallsRef? := some pendingControlCallsRef
      broadcastHub? := some broadcastHub
      relayHub? := some relayHub
      cloudHub? := some cloudHub
      providerHub? := some providerHub
      systemHub? := some systemHub
      remoteSup? := some remoteSup
    }
    if maxRequests?.isNone then
      startCloudSupervisorLoop cloudHub store (some broadcastHub) cfg.port
    let bindHost := if cfg.host == "localhost" then "127.0.0.1" else cfg.host
    let .ok (listenFd, boundPort) ← tcpListen bindHost cfg.port 128
      | do
        closeManagedComputeStore managedStore
        closeCoreStore store
        IO.eprintln s!"[sandboxed-sh] FATAL: failed to bind {bindHost}:{cfg.port}"
        return 1
    remoteSup.boundPortRef.set boundPort
    let lostTurns ← interruptTurnsLostToRestart store.missionsDb
    if lostTurns > 0 then
      IO.eprintln s!"[sandboxed-sh] {lostTurns} mission turn(s) lost to the restart marked interrupted"
    -- Only the process that owns the port fences receipts a previous process left
    -- open: such a spawn cannot be resumed or safely replayed.
    if let .error e ← ManagedSpawnActions.fenceInterrupted store then
      IO.eprintln s!"[sandboxed-sh] managed spawn action recovery failed: {e}"
    IO.eprintln s!"[sandboxed-sh] listening on http://{bindHost}:{boundPort} (dev_mode={cfg.devMode})"
    if maxRequests?.isNone then
      let localWakeupLaunch : MissionRecord → String → Option String → IO Bool :=
        fun mr prompt sid? => do
          match ← launchLocalCoreMissionTurn appState mr.id mr.backend mr.workingDirectory prompt mr.modelOverride mr.modelEffort "bypassPermissions" sid? "local" false with
          | .ok _ => return true
          | .error _ => return false
      discard <| IO.asTask (prio := .dedicated) do
        -- An error in one pass must never end the scheduler for the life of the process.
        try
          let reattached ← reattachActiveRemoteJobsOnStartup store (some managedStore) (some relayHub) (some broadcastHub) remoteSup cfg.workingDir
          if reattached > 0 then
            IO.eprintln s!"[sandboxed-sh] re-attached {reattached} active remote-node job(s)"
        catch e =>
          IO.eprintln s!"[sandboxed-sh] remote job re-attach failed: {e}"
        while true do
          try
            discard <| tickContinuationScheduler store (some managedStore) (some relayHub) (some broadcastHub) remoteSup (some warmMgr) cfg.workingDir (some localWakeupLaunch)
          catch e =>
            IO.eprintln s!"[sandboxed-sh] wake-up scheduler pass failed: {e}"
          IO.sleep 2000
      discard <| IO.asTask (prio := .dedicated) do
        let mut lastInventory : UInt64 := 0
        let mut lastSampledMinute : UInt64 := 0
        while true do
          let cached ← managedRef.get
          let observedAt ← coreEpochSec
          -- One compute sample per minute feeds the Resources history.
          if observedAt / 60 != lastSampledMinute then
            lastSampledMinute := observedAt / 60
            if let .error e ← OrbCore.ResourcesAndSystem.sampleComputeRollup store (some managedStore) observedAt then
              IO.eprintln s!"[orb-core] compute sample skipped: {e}"
          if cached.enabled || cached.machines.any (fun m => m.status != "destroyed") then
            match ← ManagedTtl.tick managedStore store cached (resolveManagedProvider store.rootDir) observedAt with
            | .error e => IO.eprintln s!"[orb-core] managed TTL maintenance deferred: {e}"
            | .ok report =>
              let reaped := ((report.fieldArr? "reaped").getD #[]).size
              if reaped > 0 then IO.eprintln s!"[orb-core] verified expiry cleanup for {reaped} managed lease(s)"
          if observedAt ≥ lastInventory + 120 &&
              (cached.boatEnabled || cached.machines.any (fun m => canonicalizeProvider m.provider == "boat" && m.status != "destroyed")) then
            lastInventory := observedAt
            match ← reconcileConfiguredBoatInventory managedStore store.rootDir observedAt with
            | .error e => IO.eprintln s!"[orb-core] Boat inventory reconciliation deferred: {e}"
            | .ok report =>
              let bound := ((report.fieldArr? "backfilled").getD #[]).size
              let stopped := ((report.fieldArr? "stopped").getD #[]).size
              let closed := ((report.fieldArr? "closed").getD #[]).size
              if bound + stopped + closed > 0 then
                IO.eprintln s!"[orb-core] Boat inventory reconciled: {bound} bindings, {stopped} stopped, {closed} closed reservations"
              if let .ok fresh ← loadManagedFleet managedStore cached.enabled cached.boatEnabled
                  cached.dailyCapCents cached.spentTodayCents cached.maxConcurrent then
                managedRef.set fresh
          if let .ok fresh ← loadManagedFleet managedStore cached.enabled cached.boatEnabled
              cached.dailyCapCents cached.spentTodayCents cached.maxConcurrent then
            managedRef.set fresh
          IO.sleep 30000
    let notifySock := ((← IO.getEnv "NOTIFY_SOCKET").getD "").trimAscii.toString
    let simulateWedge := ((← IO.getEnv "SANDBOXED_SH_SIMULATE_WEDGE").getD "") == "1"
    let watchdogUsec := ((← IO.getEnv "WATCHDOG_USEC").bind String.toNat?).getD 0
    let wdIntervalSec : UInt64 :=
      if watchdogUsec > 0 then (max 1 (watchdogUsec / 2000000)).toUInt64 else 15
    if !notifySock.isEmpty then
      discard <| sdNotifyRaw notifySock s!"READY=1\nSTATUS=Listening on {bindHost}:{boundPort}\n"
    let mut lastWatchdogSec : UInt64 := nowBootSec
    let mut lastTelFlushSec : UInt64 := nowBootSec
    let mut served : Nat := 0
    while (match maxRequests? with | some lim => decide (served < lim) | none => true) do
      match ← tcpAcceptPoll listenFd 250 with
      | .error _ =>
        if maxRequests?.isNone then
          let curSec ← coreEpochSec
          if !notifySock.isEmpty && !simulateWedge && curSec ≥ lastWatchdogSec + wdIntervalSec then
            lastWatchdogSec := curSec
            discard <| sdNotifyRaw notifySock "WATCHDOG=1\n"
          if curSec ≥ lastTelFlushSec + 30 then
            lastTelFlushSec := curSec
            discard <| IO.asTask (prio := .dedicated) (do discard <| flushTelemetryOnce telemetrySink curSec)
      | .ok cfd =>
        if maxRequests?.isSome then
          handleClientConn appState cfd false
        else
          discard <| IO.asTask (prio := .dedicated) (handleClientConn appState cfd true)
          if !notifySock.isEmpty && !simulateWedge then
            let curSec ← coreEpochSec
            if curSec ≥ lastWatchdogSec + wdIntervalSec then
              lastWatchdogSec := curSec
              discard <| sdNotifyRaw notifySock "WATCHDOG=1\n"
        served := served + 1
    if !notifySock.isEmpty then
      discard <| sdNotifyRaw notifySock "STOPPING=1\n"
    discard <| closeFd listenFd
    closeManagedComputeStore managedStore
    closeCoreStore store
    return 0

end OrbCore.Control
