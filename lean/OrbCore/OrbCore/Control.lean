/-
  OrbCore.Control: Pure-Lean Core HTTP/WS Gateway (`sandboxed-sh`), Fail-Closed Startup Security,
  JWT Subprotocol Auth (`:80/api/console/ws`), Privilege Lease Verification, Mission Control,
  Automations & Model-Routing Dispatcher (`0 import Lean`, `0 sorryAx`).
-/
import LeanSys
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.PrivdShared
import OrbCore.Spec
import OrbCore.Store
import OrbCore.Search
import OrbCore.Harness
import OrbCore.Proxy
import OrbCore.Cyber
import OrbCore.Skills
import OrbCore.Managed
import OrbCore.MemoryAndCloud

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
open OrbCore.Managed
open OrbCore.MemoryAndCloud

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
  cfg            : CoreConfig
  store          : CoreStore
  searchIdx?     : Option SearchIndex
  managedRef     : IO.Ref ManagedFleetState
  chainsRef      : IO.Ref (Array RoutingChain)
  proxyCooldownsRef : IO.Ref (Array AccountCooldown)
  seqRef         : IO.Ref UInt64
  pacingTracker?  : Option ProxyPacingTracker := none
  memTokenCache?  : Option MemoryTokenCache := none
  cloudWakeup?    : Option CloudWorkerWakeup := none
  bunkerStateRef? : Option (IO.Ref UInt8) := none

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

private def matchProviderForChainTarget? (providers : Array AIProviderRecord) (acctId provId : String) : Option AIProviderRecord :=
  let stripped := if provId.startsWith "custom:" then (provId.drop 7).toString else provId
  providers.find? fun p =>
    p.enabled && (p.id == acctId || p.id == stripped || (!provId.startsWith "custom:" && p.providerType == provId))

/-- Parse `models_json` array into `ProviderTarget` list for `RoutingChain` hydration,
    enriching targets with account & per-model pacing limits from `ai_providers`. -/
def parseChainTargetsJson (rawJson : String) (providers : Array AIProviderRecord := #[]) : Array ProviderTarget := Id.run do
  match OrbBin.Json.parse rawJson with
  | .ok (.arr items) =>
    let mut out : Array ProviderTarget := #[]
    for it in items do
      let provRaw := (it.fieldStr? "provider_id").orElse (fun _ => it.fieldStr? "provider") |>.getD "openai"
      let defaultAcct :=
        if provRaw.startsWith "custom:" then (provRaw.drop 7).toString else "default"
      let acctRaw := (it.fieldStr? "account_id").orElse (fun _ => it.fieldStr? "accountId") |>.getD defaultAcct
      let mdl := (it.fieldStr? "model_id").orElse (fun _ => it.fieldStr? "modelId") |>.getD ""
      let matchedProv? := matchProviderForChainTarget? providers acctRaw provRaw
      let matchedModel? := matchedProv?.bind (fun p => p.customModels.find? (fun cm => cm.id == mdl))
      let acct := match matchedProv? with | some p => p.id | none => acctRaw
      let url :=
        (it.fieldStr? "base_url").orElse (fun _ => it.fieldStr? "baseUrl")
        |>.orElse (fun _ => matchedProv?.bind (fun p => if p.baseUrl.isEmpty then none else some p.baseUrl))
        |>.getD "https://api.openai.com"
      let key :=
        (it.fieldStr? "api_key").orElse (fun _ => it.fieldStr? "apiKey")
        |>.orElse (fun _ => matchedProv?.map (·.apiKey))
        |>.getD ""
      let inlineAcctRpm? := (parseOptionalBoundedU32 it "rpm_limit" 1 100000).toOption.join
      let inlineAcctConc? := (parseOptionalBoundedU32 it "max_concurrency" 1 1024).toOption.join
      let inlineMdlRpm? := (parseOptionalBoundedU32 it "model_rpm_limit" 1 100000).toOption.join
      let inlineMdlTpm? := (parseOptionalBoundedU64 it "model_tpm_limit" 1 1000000000).toOption.join
      let inlineMdlConc? := (parseOptionalBoundedU32 it "model_max_concurrency" 1 1024).toOption.join
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

/-- Hydrate `RoutingChain` table from `missions.db` (`model_routing_chains` + `ai_providers`). -/
def loadRoutingChainsFromStore (st : CoreStore) : IO (Array RoutingChain) := do
  let providers ← listAIProviders st
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
      out := out.push { id := cid, name := nm, targets := parseChainTargetsJson mj providers }
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

private def selectRoutingChainForBody (chains : Array RoutingChain) (body : ByteArray) : RoutingChain :=
  let reqModel? :=
    (String.fromUTF8? body).bind fun raw =>
      match OrbBin.Json.parse raw with
      | .ok jv => jv.fieldStr? "model"
      | .error _ => none
  match reqModel?.bind (fun m => chains.find? (fun c => c.id == m || c.name == m)) with
  | some matched => matched
  | none => chains[0]?.getD { id := "default", name := "default", targets := #[] }

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
        "Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key, X-Paloma-Approval, X-Orb-Token, X-Language, Last-Event-ID, Cache-Control, Accept\r\n" ++
        "Access-Control-Expose-Headers: X-Orb-Events-Protocol, X-Has-More, X-Next-Cursor, X-Page-Max-Sequence, X-Max-Sequence, Content-Disposition, Retry-After, X-Request-Id\r\n" ++
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
  let chains ← st.chainsRef.get
  let activeChain := selectRoutingChainForBody chains req.bodySlice.toByteArray
  let cooldowns ← st.proxyCooldownsRef.get
  let plan := planChain activeChain cooldowns nowEpochSec
  if plan.eligible.isEmpty && !plan.cooling.isEmpty then
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
  let forwardBody ← match expected? with
    | none => pure req.bodySlice.toByteArray
    | some program =>
      match injectAccessProgram req.bodySlice.toByteArray program with
      | .ok b => pure b
      | .error e => return mkJson 400 s!"\{\"error\":\"unsupported_access_program\",\"detail\":{jsonEscape e}}"
  let skipAccountIds := plan.cooling.map (fun c => c.accountId)
  let out ← forwardProxyChain effectiveChain req.method cleanPath #[] forwardBody none false st.pacingTracker?
    (skipAccountIds := skipAccountIds)
  let stillActive := activeCooldowns cooldowns nowEpochSec
  let withoutSelected := stillActive.filter (fun c => c.accountId != out.selectedAccount)
  let refreshed :=
    match cooldownForOutcome out nowEpochSec with
    | some c => withoutSelected.push c
    | none => withoutSelected
  st.proxyCooldownsRef.set refreshed
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
  return { status := out.status, contentType := out.contentType, corsOrigin? := reqOrigin?, extraHdrs := out.headers, body := out.body }

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
    return .ok (← handleProxyRequest st req cleanPath reqOrigin? nowEpochSec)

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
    let bunkerWord := bunkerStep 0 0 0 0 0
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
    let toctouWord := authToctouExecuteStep principalKind bunkerState
      tgtHash execHash
      lease.expiresAtEpoch lease.expiresAtEpoch nowEpochSec lease.expiresAtEpoch
      cmdDigest cmdDigest
    let allowExec := cmdScopeOk && (privWord &&& 1) == 1 && toctouWord == 257
    if let .error e ← appendPrivilegeAuditLog st.store lease.grantId missionId targetHost execHost cmdText allowExec s!"{nowEpochSec}" then
      return .ok (mkJson 500 s!"\{\"allow_exec\":false,\"allowed\":false,\"error\":{jsonEscape e}}")
    if !allowExec then
      return .ok (mkJson 403 "{\"allow_exec\":false,\"allowed\":false,\"error\":\"lease_denied\"}")
    let rfStr := if lease.requireForceCmd then "true" else "false"
    let unitsRaw := if lease.allowedUnitsJson.startsWith "[" then lease.allowedUnitsJson else "[]"
    return .ok (mkJson 200 s!"\{\"allow_exec\":true,\"allowed\":true,\"grant_id\":{jsonEscape lease.grantId},\"scope\":{jsonEscape lease.scope},\"allowed_units\":{unitsRaw},\"require_force_cmd\":{rfStr}}")

  -- 5b. Unified Control-Plane MCP Gateway (`/api/mcp/session`, `/api/mcp/renew`, `/api/mcp/capabilities`, `/api/mcp/call`)
  if cleanPath.startsWith "/api/mcp/" then
    let bearerTok? := extractBearerToken? req.headers nowEpochSec
    let scopedClaims? := bearerTok?.bind (verifyScopedMcpToken? st.cfg.jwtSecret · nowEpochSec)
    let coreAuthed := authenticateHttpBearer st.cfg req.headers nowEpochSec

    if req.method == "POST" && cleanPath == "/api/mcp/session" then
      if !coreAuthed then
        return .ok (mkJson 401 "{\"error\":\"unauthorized_mcp_session\"}")
      let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
      let mid := (jv.fieldStr? "mission_id").getD ""
      if mid.trimAscii.toString.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"missing_mission_id\"}")
      let role := normalizeMcpRole ((jv.fieldStr? "role").getD "executor")
      let proj := (jv.fieldStr? "project").getD ""
      let sid ← nextMcpSessionUuid st
      let exp := nowEpochSec + 3600
      let claims : McpSessionClaims := {
        sessionId := sid, missionId := mid, role := role,
        project := proj, isExternal := false, expiresAt := exp
      }
      let scopedTok := mintScopedMcpToken st.cfg.jwtSecret claims
      return .ok (mkJson 200 s!"\{\"token\":{jsonEscape scopedTok},\"session_id\":{jsonEscape sid},\"expires_at\":{exp}}")

    if req.method == "POST" && cleanPath == "/api/mcp/renew" then
      let some prev := scopedClaims?
        | return .ok (mkJson 401 "{\"error\":\"invalid_or_expired_scoped_token\"}")
      let nextExp := nowEpochSec + 3600
      let renewed : McpSessionClaims := { prev with expiresAt := nextExp }
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
              if pk == "managed_vm" || pk.startsWith "managed-" || mTags.any (fun t => t.startsWith "managed-" || t == "placement:managed_vm") then
                onManagedNode := true
              if !activeClaims.isExternal && (!mProj.isEmpty || mTags.contains "skill:spark-memory") then
                hasProjSkill := true
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
        let unsupportedJson := renderCompact (.obj #[
          ("ok", .bool false),
          ("error", .obj #[
            ("code", .str "unknown_tool"),
            ("message", .str s!"Unknown or unsupported MCP tool `{toolName}`"),
            ("accepted", .str "no"),
            ("retryable", .bool false)
          ])
        ])
        return .ok (mkJson 200 unsupportedJson)

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

  -- Mission Remote Wait Arm (`POST /api/control/missions/:id/remote-wait`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/remote-wait" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
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
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Mission Remote Replay Step (`POST /api/control/missions/:id/remote-replay`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/remote-replay" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
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
        return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Stranded Pending Reconciliation (`POST /api/control/missions/reconcile-pending`)
  if req.method == "POST" && cleanPath == "/api/control/missions/reconcile-pending" then
    match ← reconcileStrandedPendingMissions st.store.missionsDb s!"{nowEpochSec}" with
    | .ok n => return .ok (mkJson 200 s!"\{\"ok\":true,\"healed\":{n}}")
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  -- Mission Fork & Cloud-to-Workspace Handoff (`POST /api/control/missions/:id/fork`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/fork" rawTarget then
    if req.method == "POST" then
      let srcMid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let jv :=
        if req.bodySlice.len == 0 then JVal.obj #[]
        else match OrbBin.Json.parseBytes req.bodySlice.toByteArray with
          | .ok v => v
          | .error _ => .null
      if jv == .null then
        return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let defNewId ← nextUniqueId st "m" nowEpochSec
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
      let remoteNodeId? := jv.fieldStr? "remote_node_id"
      let isRemoteTarget :=
        match remoteNodeId? with
        | some rn =>
          let t := rn.trimAscii.toString
          !t.isEmpty && t != "local"
        | none => false
      let rawWd? := jv.fieldStr? "working_directory"
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
        nowAt := s!"{nowEpochSec}"
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
        let body :=
          s!"\{\"id\":{jsonEscape out.missionId},\"title\":{jsonEscape out.title},\"status\":\"awaiting_user\"," ++
          s!"\"backend\":{jsonEscape out.backend},\"model_override\":{modOvJson},\"model_effort\":{effJson}," ++
          s!"\"working_directory\":{jsonEscape out.workingDirectory},\"remote_node_id\":{rnJson}," ++
          s!"\"forked_from\":{jsonEscape out.forkedFrom},\"turns_copied\":{out.turnsCopied}," ++
          s!"\"used_cloud_turns\":{cloudTurnsStr},\"fresh_workspace\":{freshWsStr}," ++
          s!"\"state_revision\":1,\"tags\":{out.tagsJson}}"
        return .ok (mkJson 201 body)

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

  -- Mission Health Verdict (`GET /api/control/missions/:id/health`, `SM-01`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/health" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let sql :=
        "SELECT m.status,COALESCE(m.terminal_reason,''),m.orphaned_at,m.superseded_by_mission_id," ++
        "m.placement_kind,m.node_boot_epoch,m.state_revision," ++
        "COALESCE(e.terminal_reason,''),COALESCE(e.summary,''),COALESCE(e.artifact_ref,''),COALESCE(e.recorded_at,'')," ++
        "(SELECT COUNT(*) FROM mission_runs r WHERE r.mission_id=m.id AND r.execution_state<>'terminal')," ++
        "(SELECT COUNT(*) FROM mission_events ev WHERE ev.mission_id=m.id) " ++
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
        let effReason := if !evReason.isEmpty then evReason else mReason
        let hasEv := !evRecorded.isEmpty || !evReason.isEmpty
        let verdict := deriveMissionHealthVerdict
          status effReason orphAt superBy placeKind
          (rowBoot == st.store.bootEpoch) false (liveRuns > 0) (evCnt > 0) false hasEv
        let evJson :=
          if hasEv then
            s!"\{\"terminal_reason\":{jsonEscape evReason},\"summary\":{jsonEscape evSummary},\"artifact_ref\":{jsonEscape evArtifact},\"recorded_at\":{jsonEscape evRecorded}}"
          else "null"
        return .ok (mkJson 200 (
          s!"\{\"mission_id\":{jsonEscape mid},\"status\":{jsonEscape status},\"health_verdict\":{jsonEscape verdict}," ++
          s!"\"state_revision\":{stateRev},\"terminal_evidence\":{evJson}}"
        ))

  -- Missions Collection (`GET|POST /api/control/missions`)
  if cleanPath == "/api/control/missions" then
    if req.method == "GET" then
      match ← listMissionsJson st.store with
      | .ok j => return .ok (mkJson 200 j)
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
    else if req.method == "POST" then
      let bodyVal? := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption
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
      let defMid ← nextUniqueId st "m" nowEpochSec
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
      let rawWorkDir := (JsonTape.lookupString? tape "working_directory").getD st.cfg.workingDir
      let .ok safeWorkDir ← confineWorkingDirectory st.cfg.workingDir rawWorkDir
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"invalid_working_directory\"}")
      let projSlug := ((JsonTape.lookupString? tape "project_slug").orElse (fun _ => JsonTape.lookupString? tape "project")).getD ""
      let track := (JsonTape.lookupString? tape "track").getD ""
      let repo := ((JsonTape.lookupString? tape "github_pr").orElse (fun _ => JsonTape.lookupString? tape "repo")).getD ""
      let placeKind := (JsonTape.lookupString? tape "placement_kind").getD "managed"
      let rawDiskNat := (JsonTape.lookupNat? tape "estimated_disk_gib").getD 0
      if rawDiskNat > maxReservedDiskGib.toNat then
        abortIdem
        return .ok (mkJson 400 "{\"error\":\"invalid_estimated_disk_gib\"}")
      let diskGib := rawDiskNat.toUInt64
      let writerFlag? := bodyVal?.bind (·.fieldBool? "writer")
      let reqTags : Array String :=
        match bodyVal?.bind (·.fieldArr? "tags") with
        | some xs => xs.filterMap (fun v => match v with | .str s => some s | _ => none)
        | none => #[]
      let intentStr := (JsonTape.lookupString? tape "intent").getD ""
      let .ok authMode := classifyAuthorityMode writerFlag? reqTags (intentStr == "review_only" || intentStr == "readonly")
        | do abortIdem; return .ok (mkJson 400 "{\"error\":\"contradictory_authority_tags\"}")
      let bodyJv := bodyVal?.getD (.obj #[])
      let modelOverride := (JsonTape.lookupString? tape "model_override").getD ""
      let prompt? := JsonTape.lookupString? tape "prompt"
      let placement? := JsonTape.lookupString? tape "placement"
      let clientPlaced := isClientPlacement placement? reqTags
      let mut selectedSkills : Array SelectedSkill := #[]
      if !clientPlaced then
        if let some prompt := prompt? then
          match ← selectDelivered st.cfg.workingDir (if projSlug.isEmpty then none else some projSlug) backend prompt with
          | .error e =>
            abortIdem
            return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
          | .ok selected =>
            selectedSkills := selected
            if (JsonTape.lookupString? tape "remote_node_id").isSome then
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
      if !projSlug.isEmpty then
        let rawCap? ← queryProjectParallelMissions? st.store projSlug
        if let some cap := enforcedProjectParallelCap? rawCap? then
          if let .ok statuses ← listProjectMissionStatuses st.store projSlug then
            let held := (statuses.filter campaignSlotHeldBy).size
            if held ≥ cap then
              abortIdem
              return .ok (mkJson 429 s!"\{\"error\":\"parallel_missions_cap\",\"cap\":{cap},\"active\":{held}}")
      let initTagsJson := projectCompatibilityTagsJson authMode placeKind "" "" diskGib reqTags
      let mRec : MissionRecord := {
        id := mid, title := title, status := "awaiting_user", backend := backend,
        modelOverride := modelOverride, modelEffort := normEffort, workingDirectory := safeWorkDir,
        project := projSlug, updatedAt := s!"{nowEpochSec}", totalCostCents := 0,
        authorityMode := authMode, placementKind := placeKind, reservedDiskGib := diskGib,
        nodeBootEpoch := st.store.bootEpoch, tagsJson := initTagsJson, track := track, repo := repo
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
        if !projSlug.isEmpty && !track.isEmpty then
          let resId ← nextUniqueId st "rsv" nowEpochSec
          leaseReservationId := resId
          let leaseReq : DispatchLeaseRequest := {
            reservationId := resId, missionId := mid, projectSlug := projSlug,
            track := track, repo := repo, authorityMode := authMode,
            reservedDiskGib := diskGib, bootEpoch := st.store.bootEpoch, nowAt := s!"{nowEpochSec}"
          }
          if let .error leaseErr ← acquireDispatchTrackLease st.store leaseReq then
            discard <| execParamQuery st.store.missionsDb "DELETE FROM missions WHERE id=?1;" #[mid]
            discard <| recoverDispatchLeases st.store.missionsDb st.store.projectsDb st.store.bootEpoch
            abortIdem
            return .ok (mkJson 409 s!"\{\"error\":{jsonEscape leaseErr}}")
        let deliveredPromptField :=
          match prompt? with
          | some p =>
            if selectedSkills.isEmpty then ""
            else s!",\"delivered_prompt\":{jsonEscape (withDirective p selectedSkills)}"
          | none => ""
        let respBody :=
          s!"\{\"id\":{jsonEscape mid},\"status\":\"awaiting_user\",\"backend\":{jsonEscape backend}," ++
          s!"\"model_override\":{jsonEscape modelOverride},\"model_effort\":{jsonEscape normEffort}," ++
          s!"\"authority_mode\":{jsonEscape authMode},\"placement_kind\":{jsonEscape placeKind}," ++
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
      let hits ← queryConversations sIdx q 32
      let hitJson := "[" ++ String.intercalate "," (hits.toList.map jsonEscape) ++ "]"
      return .ok (mkJson 200 s!"\{\"hits\":{hitJson}}")

  -- AI Providers CRUD & Rate-Limit Metadata (`/api/ai/providers`, `/api/ai/providers/:id`)
  if cleanPath == "/api/ai/providers" || cleanPath.startsWith "/api/ai/providers/" then
    if req.method == "GET" && cleanPath == "/api/ai/providers" then
      let providers ← listAIProviders st.store
      let mut items : Array String := Array.mkEmpty providers.size
      for p in providers do
        let obs? ← match st.pacingTracker? with
          | some tr => lookupObservedKeyRpm? tr p.id
          | none => pure none
        items := items.push (renderAIProviderJson p obs?)
      return .ok (mkJson 200 ("[" ++ String.intercalate "," items.toList ++ "]"))
    else if req.method == "POST" && cleanPath == "/api/ai/providers" then
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
        let refreshed ← loadRoutingChainsFromStore st.store
        st.chainsRef.set refreshed
        return .ok (mkJson 201 (renderAIProviderJson provRec none))
    else if let some params := matchRoutePattern? "/api/ai/providers/:id" rawTarget then
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
          let refreshed ← loadRoutingChainsFromStore st.store
          st.chainsRef.set refreshed
          let obs? ← match st.pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr updated.id
            | none => pure none
          return .ok (mkJson 200 (renderAIProviderJson updated obs?))
      else if req.method == "DELETE" then
        match ← deleteAIProvider st.store pid with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok () =>
          let refreshed ← loadRoutingChainsFromStore st.store
          st.chainsRef.set refreshed
          return .ok (mkJson 200 "{\"ok\":true}")

  -- Model Routing Controls (`"/api/model-routing"` / `/api/model-routing/chains`)
  if cleanPath.startsWith "/api/model-routing" then
    if let some params := matchRoutePattern? "/api/model-routing/chains/:id/resolve" rawTarget then
      if req.method == "GET" then
        let cid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
        let chains ← loadRoutingChainsFromStore st.store
        st.chainsRef.set chains
        match chains.find? (fun c => c.id == cid) with
        | none => return .ok (mkJson 404 "{\"error\":\"chain_not_found\"}")
        | some ch =>
          let resolvedJson ← renderResolvedChainJson ch st.pacingTracker?
          return .ok (mkJson 200 resolvedJson)
    if req.method == "GET" && cleanPath == "/api/model-routing/chains" then
      let rows ← execParamQuery st.store.missionsDb
        "SELECT id,name,models_json,updated_at FROM model_routing_chains ORDER BY id ASC;" #[]
      return .ok (mkJson 200 (match rows with | .ok rs => rowsToJsonArray rs | .error _ => "[]"))
    else if (req.method == "POST" && cleanPath == "/api/model-routing/chains") ||
            (req.method == "PUT" && (matchRoutePattern? "/api/model-routing/chains/:id" rawTarget).isSome) then
      let pathCid? := (matchRoutePattern? "/api/model-routing/chains/:id" rawTarget).bind fun ps =>
        (ps.find? (fun p => p.1 == "id")).map Prod.snd
      let rawBody := String.fromUTF8? req.bodySlice.toByteArray |>.getD "{}"
      let jv := (OrbBin.Json.parse rawBody).toOption.getD (.obj #[])
      let defCid ← nextUniqueId st "chain" nowEpochSec
      let cid := pathCid?.orElse (fun _ => jv.fieldStr? "id") |>.getD defCid
      let nm := (jv.fieldStr? "name").getD cid
      let modelsJson := match (jv.field? "models").orElse (fun _ => jv.field? "entries") with
        | some arr@(.arr _) => renderCompact arr
        | _ => (jv.fieldStr? "models_json").getD "[]"
      match ← execParamQuery st.store.missionsDb
        "INSERT OR REPLACE INTO model_routing_chains(id,name,models_json,updated_at) VALUES(?1,?2,?3,?4);"
        #[cid, nm, modelsJson, s!"{nowEpochSec}"] with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok _ =>
        let refreshed ← loadRoutingChainsFromStore st.store
        st.chainsRef.set refreshed
        return .ok (mkJson (if req.method == "POST" then 201 else 200) s!"\{\"id\":{jsonEscape cid},\"name\":{jsonEscape nm}}")
    else
      return .ok (mkJson 200 "{\"ok\":true,\"router\":\"/api/model-routing\"}")

  -- Managed Compute Fleet (`/api/managed-machines/spend`, `/api/remote-nodes`)
  if req.method == "GET" && (cleanPath == "/api/managed-machines/spend" || cleanPath == "/api/managed-machines") then
    let mf ← st.managedRef.get
    return .ok (mkJson 200 (renderManagedBudgetJson mf))

  if req.method == "GET" && cleanPath == "/api/remote-nodes" then
    let mf ← st.managedRef.get
    return .ok (mkJson 200 s!"\{\"nodes\":[],\"managed_compute\":{renderManagedBudgetJson mf}}")

  -- Durable follow-up queue (`GET /api/control/queue`, `PATCH /api/control/queue/:id`)
  if req.method == "GET" && cleanPath == "/api/control/queue" then
    let missionId := ((parseQueryParams rawTarget).find? (fun p => p.1 == "mission_id")).map Prod.snd |>.getD ""
    if missionId.isEmpty then
      return .ok (mkJson 400 "{\"error\":\"missing_mission_id\"}")
    match ← listRemoteQueueJson st.store "core" missionId with
    | .ok body => return .ok (mkJson 200 body)
    | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")

  if let some params := matchRoutePattern? "/api/control/queue/:id" rawTarget then
    if req.method == "PATCH" then
      let messageId := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray
        | return .ok (mkJson 400 "{\"error\":\"invalid_json\"}")
      let some rawContent := jv.fieldStr? "content"
        | return .ok (mkJson 400 "{\"error\":\"content must be a string\"}")
      let content := rawContent.trimAscii.toString
      if content.isEmpty then
        return .ok (mkJson 400 "{\"error\":\"A queued message cannot be empty; remove it instead\"}")
      match ← editRemoteMessage st.store "core" messageId content with
      | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
      | .ok .NotFound => return .ok (mkJson 404 "{\"error\":\"message not in queue\"}")
      | .ok .AlreadyDelivered =>
        return .ok (mkJson 409 "{\"error\":\"This message was already sent; it can no longer be edited\"}")
      | .ok (.Edited missionId source?) =>
        let sourceJson := match source? with | some s => jsonEscape s | none => "null"
        let eventPayload := s!"\{\"type\":\"user_message\",\"id\":{jsonEscape messageId},\"content\":{jsonEscape content},\"queued\":true,\"mission_id\":{jsonEscape missionId},\"source\":{sourceJson}}"
        let seq ← st.seqRef.modifyGet fun n => (n + 1, n + 1)
        match ← execParamQuery st.store.missionsDb
          "INSERT INTO mission_events(mission_id,seq,event_type,payload,created_at) VALUES(?1,?2,'user_message',?3,?4);"
          #[missionId, s!"{seq}", eventPayload, s!"{nowEpochSec}"] with
        | .error e => return .ok (mkJson 500 s!"\{\"error\":{jsonEscape e}}")
        | .ok _ => return .ok (mkJson 200 s!"\{\"ok\":true,\"id\":{jsonEscape messageId},\"content\":{jsonEscape content}}")

  -- Mission Cyber Access (`GET|PATCH /api/control/missions/:id/cyber`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/cyber" rawTarget then
    let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
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
      let proj? := mission?.bind (fun m => if m.project.isEmpty then none else some m.project)
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
    let deliveredField :=
      if selectedSkills.isEmpty then ""
      else s!",\"delivered_prompt\":{jsonEscape (withDirective content selectedSkills)}"
    return .ok (mkJson 200 s!"\{\"id\":{jsonEscape msgId},\"queued\":false,\"message_accepted\":true{deliveredField}}")

  -- Mission Resume (`POST /api/control/missions/:id/resume`)
  if let some params := matchRoutePattern? "/api/control/missions/:id/resume" rawTarget then
    if req.method == "POST" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if !isSafeMissionId mid then
        return .ok (mkJson 400 "{\"error\":\"invalid_mission_id\"}")
      let some m ← getMission? st.store mid
        | return .ok (mkJson 404 "{\"error\":\"Mission not found\"}")
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
          let proj? := if m.project.isEmpty then none else some m.project
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
      return .ok (mkJson 200 s!"\{\"id\":{jsonEscape mid},\"status\":\"active\"{deliveredField}}")

  -- Single Mission Lookup (`GET /api/control/missions/:id`)
  if let some params := matchRoutePattern? "/api/control/missions/:id" rawTarget then
    if req.method == "GET" then
      let mid := (params.find? (fun p => p.1 == "id")).map Prod.snd |>.getD ""
      if mid != "search" then
        let some m ← getMission? st.store mid
          | return .ok (mkJson 404 "{\"error\":\"Mission not found\"}")
        return .ok (mkJson 200 s!"\{\"id\":{jsonEscape m.id},\"title\":{jsonEscape m.title},\"status\":{jsonEscape m.status},\"backend\":{jsonEscape m.backend},\"model_override\":{jsonEscape m.modelOverride},\"model_effort\":{jsonEscape m.modelEffort},\"working_directory\":{jsonEscape m.workingDirectory},\"project\":{jsonEscape m.project},\"updated_at\":{jsonEscape m.updatedAt},\"total_cost_cents\":{m.totalCostCents}}")

  -- Delivered skill catalog (`GET /api/library/skill-delivery`)
  if req.method == "GET" && cleanPath == "/api/library/skill-delivery" then
    let q := parseQueryParams rawTarget
    let proj? := (q.find? (fun p => p.1 == "project")).map Prod.snd
    match ← buildDeliveryPlan st.cfg.workingDir proj? with
    | .error e => return .ok (mkJson 400 s!"\{\"error\":{jsonEscape e}}")
    | .ok plan => return .ok (mkJson 200 (planToJson plan))

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
    let normWork := trimTrailingSlashes cfg.workingDir.trimAscii.toString
    let dataRoot :=
      if normWork.endsWith "/.sandboxed-sh" || normWork == ".sandboxed-sh" then normWork
      else s!"{normWork}/.sandboxed-sh"
    let .ok store ← openCoreStore dataRoot
      | do IO.eprintln s!"[sandboxed-sh] FATAL: failed to open SQLite CoreStore at {dataRoot}"; return 1
    let searchRes ← openSearchIndex s!"{dataRoot}/search_index"
    let managedRef ← IO.mkRef ({} : ManagedFleetState)
    let initialChains ← loadRoutingChainsFromStore store
    let chainsRef ← IO.mkRef initialChains
    let proxyCooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
    let seqRef ← IO.mkRef (0 : UInt64)
    let pacingTracker ← newProxyPacingTracker
    let memTokenCache ← newMemoryTokenCache
    let cloudWakeup ← newCloudWorkerWakeup
    let bunkerRef ← IO.mkRef (0 : UInt8)
    let appState : CoreAppState := {
      cfg := cfg
      store := store
      searchIdx? := searchRes.toOption
      managedRef := managedRef
      chainsRef := chainsRef
      proxyCooldownsRef := proxyCooldownsRef
      seqRef := seqRef
      pacingTracker? := some pacingTracker
      memTokenCache? := some memTokenCache
      cloudWakeup? := some cloudWakeup
      bunkerStateRef? := some bunkerRef
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
        if maxRequests?.isSome then
          handleClientConn appState cfd
        else
          discard <| IO.asTask (prio := .dedicated) (handleClientConn appState cfd)
        served := served + 1
    discard <| closeFd listenFd
    closeCoreStore store
    return 0

end OrbCore.Control
