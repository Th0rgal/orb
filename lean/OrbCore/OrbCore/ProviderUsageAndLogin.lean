/-
  OrbCore.ProviderUsageAndLogin:
  Production AI Provider Hydration, Subscription Rate-Limit Usage, CLIProxy Login,
  AI Usage Summary, Proxy Health/Timing, Model-Routing Health/Test, Antigravity Model Cache,
  and Provider Catalog/Discovery Surface (`0 import Lean`, `0 sorryAx`).

  Covers:
  - Rich `ProviderResponse` hydration merging SQLite `ai_providers` + `.sandboxed-sh/ai_providers.json`
    + `.sandboxed-sh/default_provider.json` + `.sandboxed-sh/provider_backends.json` + CLIProxy auth files
    across `/var/lib/cli-proxy-api`, `$HOME/.cli-proxy-api` (`/root/.cli-proxy-api`), and `{mgmt}/auth-files`
  - `GET /api/ai/providers/usage` & `GET /api/ai/providers/:id/usage` (with `optimize` block & 120s/600s cache)
  - `GET|POST /api/ai/providers/cli-proxy-login`, `GET|DELETE /api/ai/providers/cli-proxy-login/:id`,
    `POST /api/ai/providers/cli-proxy-login/:id/callback`
  - `GET /api/ai/providers/:id`, `POST /api/ai/providers/reorder`, `GET /api/ai/providers/types`,
    `GET /api/ai/providers/for-backend/:backend_id`, `POST /api/ai/providers/:id/{default,health,reset-usage,antigravity/recheck}`,
    `GET /api/ai/providers/:id/auth/methods`
  - `GET /api/ai/usage/summary`, `GET /api/ai/proxy/health`, `GET /api/ai/proxy/timing`
  - `GET /api/model-routing/health`, `POST /api/model-routing/health/:account_id/clear`, `POST /api/model-routing/chains/:id/test`
  - `GET /api/providers/discovery`, `GET /api/providers/catalog`, `GET /api/providers/snapshots`, `POST /api/providers/catalog/refresh`
  - 300s `AntigravityModelsCache` so `/api/providers/antigravity-models` and `/api/providers/backend-models` never block
-/
import Std.Sync.Mutex
import Orb.ProviderLogin
import OrbCore.ProviderCredentialIdentity
import OrbCore.AccountVpnRoutes
import OrbCore.AccountVpnSidecar
import LeanSys.Auth
import LeanSys.Http
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.Sqlite
import OrbBin.HttpClient
import OrbBin.ClaudeControl
import OrbCore.Store
import OrbCore.Proxy
import OrbCore.ProxyModelRouting
import OrbCore.R7Core
import OrbCore.LegacyHydrate

namespace OrbCore.ProviderUsageAndLogin

open LeanSys.Auth
open LeanSys.Http
open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.Sqlite
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.Proxy
open OrbCore.ProxyModelRouting
open OrbCore.R7Core
open OrbCore.LegacyHydrate

/-- Caller-visible model overrides configured on provider accounts. Custom routes
    use the provider name understood by directEntry?, rather than the account UUID. -/
def configuredOpenCodeOptions (store : CoreStore) (userId : String) (admin : Bool) : IO (Array JVal) := do
  let prefs ← getUserProviderPrefs store userId
  let mut options : Array JVal := #[]
  for p in ← listAIProviders store do
    if p.enabled && (admin || !p.apiKey.isEmpty) && isUserProviderEnabled prefs p.id then
      let provider := if p.providerType == "custom" then customProviderName p.name else p.id
      for cm in p.customModels do
        let mid := cm.id.trimAscii.toString
        if !provider.isEmpty && !mid.isEmpty && customProviderModelAllowed provider p.baseUrl mid then
          let value := s!"{provider}/{mid}"
          unless options.any (fun opt => opt.fieldStr? "value" == some value) do
            let label := (cm.name?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)).getD mid
            options := options.push (.obj #[("value", .str value), ("label", .str s!"{p.name} — {label}")])
  return options

/-! ## Runtime Caches (`ProviderRuntimeHub`) -/

structure CachedUsageEntry where
  providerId  : String
  fetchedSec  : UInt64
  fetchedIso  : String
  payload     : JVal
  refreshing  : Bool := false
  deriving Repr, Inhabited

structure CliLoginSession where
  sessionId     : String
  providerSlug  : String
  authFileType  : String
  targetProvId? : Option String
  stateToken    : String
  authUrl       : String
  flow          : String
  createdSec    : UInt64
  beforeFiles   : Array (String × UInt64)
  routedFile? : Option String := none
  routeGeneration : Nat := 0
  completionStartedSec? : Option UInt64 := none
  status        : String := "pending"
  message?      : Option String := none
  /-- Caller who started the login; only they (or an admin) may poll, call back or cancel it. -/
  userId        : String := ""
  deriving Repr, Inhabited

structure ProviderHubState where
  agyModelsCache? : Option (UInt64 × Array (String × String)) := none
  usageEntries    : Array CachedUsageEntry := #[]
  usageGeneration : Nat := 0
  refreshingProviderIds : Array String := #[]
  loginSessions   : Array CliLoginSession := #[]
  catalogRefreshedSec : UInt64 := 0

/-- JSON HTTP transport of the vendor usage adapters, in the shape of `sendJsonRequest`
    (method, url, bearer, body, extra headers, timeout ms, response byte cap). Production passes
    `liveUsageHttp`; tests replay recorded vendor responses through the same adapter code. -/
abbrev UsageHttp :=
  String → String → Option String → Option JVal → Array (String × String) → UInt32 → Nat →
    IO (Except String (Nat × String × Option JVal))

/-- The production transport. -/
def liveUsageHttp : UsageHttp :=
  fun method url bearer body headers timeoutMs maxBytes =>
    sendJsonRequest method url bearer body headers timeoutMs maxBytes

structure ProviderRuntimeHub where
  mu : Std.Mutex ProviderHubState
  usageProbe? : Option (String → IO JVal) := none
  resolveTransport? : Option (String → String → ResolveTransport) := none
  accountRelayUrl? : Option (String → String → Option String) := none
  /-- Vendor transport of the usage adapters. Only tests replace it. -/
  usageHttp : UsageHttp := liveUsageHttp

def newProviderRuntimeHub : IO ProviderRuntimeHub := do
  let mu ← Std.Mutex.new ({} : ProviderHubState)
  return { mu }

/-! ## Shared Helpers -/

private def execParamStmt (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String Unit) := do
  match ← execParamQuery db sql params with
  | .ok _ => return .ok ()
  | .error e => return .error e

private def jsonResp (status : Nat) (jv : JVal) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact jv).toUTF8)

private def jsonErr (status : Nat) (msg : String) : Nat × String × ByteArray :=
  (status, "application/json", (renderCompact (.obj #[("error", .str msg), ("message", .str msg)])).toUTF8)

private def parseQueryMap (rawTarget : String) : Array (String × String) := Id.run do
  let qStr :=
    match rawTarget.splitOn "?" with
    | _ :: qs => String.intercalate "?" qs
    | [] => ""
  if qStr.isEmpty then return #[]
  let mut out : Array (String × String) := #[]
  for pair in qStr.splitOn "&" do
    if !pair.isEmpty then
      match pair.splitOn "=" with
      | [] => pure ()
      | [k] => out := out.push ((percentDecodeStrict k).getD k, "")
      | k :: vs =>
        let rawV := String.intercalate "=" vs
        out := out.push ((percentDecodeStrict k).getD k, (percentDecodeStrict rawV).getD rawV)
  return out

private def qParam? (qMap : Array (String × String)) (key : String) : Option String :=
  (qMap.find? (fun (k, _) => k == key)).map Prod.snd

private def trimQuotes (s : String) : String :=
  let t := s.trimAscii.toString
  if t.length >= 2 && ((t.startsWith "\"" && t.endsWith "\"") || (t.startsWith "'" && t.endsWith "'")) then
    ((t.drop 1).dropEnd 1).toString
  else
    t

private def parseEnvFile (raw : String) : Array (String × String) := Id.run do
  let mut out : Array (String × String) := #[]
  for line in raw.splitOn "\n" do
    let t := line.trimAscii.toString
    if !t.isEmpty && !t.startsWith "#" then
      let body := if t.startsWith "export " then (t.drop 7).toString.trimAscii.toString else t
      match body.splitOn "=" with
      | [] | [_] => pure ()
      | k :: vs =>
        let key := k.trimAscii.toString
        let val := trimQuotes (String.intercalate "=" vs)
        if !key.isEmpty then out := out.push (key, val)
  return out

private def isHermeticTestMode : IO Bool := do
  match ← IO.getEnv "ORB_HERMETIC_TEST" with
  | some v =>
    let tv := v.trimAscii.toString.toLower
    return tv == "1" || tv == "true" || tv == "yes"
  | none => return false

def lookupEnvWithFiles? (key : String) : IO (Option String) := do
  if let some v ← IO.getEnv key then
    let tv := v.trimAscii.toString
    if !tv.isEmpty then return some tv
  if ← isHermeticTestMode then
    return none
  for p in #["/etc/sandboxed-sh/cli-proxy-management.env", "/etc/open_agent/open_agent.env", "/etc/sandboxed-sh/cloud-agents-prod.env"] do
    let fp := System.FilePath.mk p
    if (← fp.pathExists) then
      if let some raw ← (try some <$> IO.FS.readFile fp catch _ => pure none) then
        if let some (_, v) := (parseEnvFile raw).find? (fun (ek, _) => ek == key) then
          if !v.isEmpty then return some v
  return none

/-! ## Cached Antigravity Models (`300s` TTL) -/

def getCachedAntigravityModels (hub : ProviderRuntimeHub) (force : Bool := false) : IO (Array (String × String)) := do
  let nowSec ← nowEpoch
  if !force then
    let hit? ← hub.mu.atomically do
      let st ← get
      match st.agyModelsCache? with
      | some (ts, pairs) => if nowSec ≤ ts + 300 then return some pairs else return none
      | none => return none
    if let some pairs := hit? then
      return pairs
  let pairs ← match ← OrbBin.ClaudeControl.resolveHarnessBinary? "agy" none with
    | none => pure #[]
    | some binPath =>
      match ← OrbBin.ClaudeControl.probeAntigravityModels binPath with
      | .ok ps => pure ps
      | .error _ => pure #[]
  hub.mu.atomically do
    let st ← get
    set { st with agyModelsCache? := some (nowSec, pairs) }
  return pairs

/-! ## CLIProxyAPI Discovery (Scanning BOTH `/var/lib/cli-proxy-api` AND `$HOME/.cli-proxy-api` / `/root/.cli-proxy-api`) -/

def resolveCliProxyBaseUrl : IO String := do
  for k in #["CLAUDE_CODE_PROXY_BASE_URL", "CLI_PROXY_API_BASE_URL", "CLIPROXY_API_BASE_URL", "CLIPROXY_BASE_URL"] do
    if let some v ← lookupEnvWithFiles? k then
      let stripped := if v.endsWith "/v1" then (v.dropEnd 3).toString else if v.endsWith "/v1/" then (v.dropEnd 4).toString else v
      return stripped
  return "http://127.0.0.1:8317"

def resolveCliProxyMgmtKey? : IO (Option String) :=
  lookupEnvWithFiles? "CLI_PROXY_MANAGEMENT_KEY"

def candidateCliProxyAuthDirs : IO (Array String) := do
  if let some explicitEnvDir ← IO.getEnv "CLI_PROXY_AUTH_DIR" then
    let clean := explicitEnvDir.trimAscii.toString
    if !clean.isEmpty then return #[clean]
  let mut dirs : Array String := #[]
  if let some envDir ← lookupEnvWithFiles? "CLI_PROXY_AUTH_DIR" then
    if !envDir.isEmpty then dirs := dirs.push envDir
  if ← isHermeticTestMode then
    return dirs
  if !dirs.contains "/var/lib/cli-proxy-api" then
    dirs := dirs.push "/var/lib/cli-proxy-api"
  let homeDir := (← IO.getEnv "HOME").getD "/root"
  let homeAuth := s!"{homeDir}/.cli-proxy-api"
  if !dirs.contains homeAuth then
    dirs := dirs.push homeAuth
  if !dirs.contains "/root/.cli-proxy-api" then
    dirs := dirs.push "/root/.cli-proxy-api"
  return dirs

def scanCliProxyAuthFiles : IO (Array CliAuthFileInfo) := do
  let dirs ← candidateCliProxyAuthDirs
  let mut out : Array CliAuthFileInfo := #[]
  let mut seenNames : Array String := #[]
  for d in dirs do
    let dfp := System.FilePath.mk d
    if (← dfp.pathExists) && (← dfp.isDir) then
      if let .ok entries ← dfp.readDir.toBaseIO then
        for e in entries do
          if e.fileName.endsWith ".json" && !seenNames.contains e.fileName then
            if let some raw ← (try some <$> IO.FS.readFile e.path catch _ => pure none) then
              if let .ok jv := OrbBin.Json.parse raw then
                let st ← statIdentity e.path.toString false
                let fType := ((jv.fieldStr? "type").getD "").trimAscii.toString.toLower
                let inferredType :=
                  if !fType.isEmpty then fType
                  else if e.fileName.startsWith "antigravity-" then "antigravity"
                  else if e.fileName.startsWith "codex-" then "codex"
                  else if e.fileName.startsWith "claude-" then "claude"
                  else if e.fileName.startsWith "kimi-" then "kimi"
                  else if e.fileName.startsWith "meta-" then "meta"
                  else if e.fileName.startsWith "xai-" then "xai"
                  else ""
                let email := ((jv.fieldStr? "email").orElse (fun _ => jv.fieldStr? "account_email") |>.getD "").trimAscii.toString
                let tok := ((jv.fieldStr? "access_token").orElse (fun _ => jv.fieldStr? "token") |>.getD "").trimAscii.toString
                let acctId := ((jv.fieldStr? "account_id").getD "").trimAscii.toString
                let pfx := ((jv.fieldStr? "prefix").getD "").trimAscii.toString
                let dis := (jv.fieldBool? "disabled").getD false
                let deviceTok := if inferredType == "meta" then ((jv.fieldStr? "dca_token").getD "").trimAscii.toString else ""
                seenNames := seenNames.push e.fileName
                out := out.push {
                  fileName := e.fileName
                  fullPath := e.path.toString
                  authType := inferredType
                  email := email
                  accessToken := tok
                  accountId := acctId
                  prefixId := pfx
                  disabled := dis
                  mtimeSec := st.mtime
                  fingerprint := hash raw
                  deviceToken := deviceTok
                }
  return out

/-! ## Built-in Provider Metadata & Rich `ProviderResponse` Hydration -/

structure ProviderTypeMeta where
  id        : String
  name      : String
  usesOAuth : Bool
  envVar?   : Option String

def allProviderTypes : Array ProviderTypeMeta := #[
  { id := "anthropic", name := "Anthropic", usesOAuth := true, envVar? := some "ANTHROPIC_API_KEY" },
  { id := "openai", name := "OpenAI", usesOAuth := true, envVar? := some "OPENAI_API_KEY" },
  { id := "google", name := "Google AI", usesOAuth := true, envVar? := some "GOOGLE_GENERATIVE_AI_API_KEY" },
  { id := "open-router", name := "OpenRouter", usesOAuth := false, envVar? := some "OPENROUTER_API_KEY" },
  { id := "xai", name := "xAI (Grok)", usesOAuth := true, envVar? := some "XAI_API_KEY" },
  { id := "kimi", name := "Kimi", usesOAuth := true, envVar? := some "KIMI_API_KEY" },
  { id := "antigravity", name := "Antigravity", usesOAuth := true, envVar? := none },
  { id := "muse-code", name := "Muse Code", usesOAuth := true, envVar? := some "META_API_KEY" },
  { id := "mistral", name := "Mistral", usesOAuth := false, envVar? := some "MISTRAL_API_KEY" },
  { id := "zai", name := "Z.ai (GLM)", usesOAuth := false, envVar? := some "ZAI_API_KEY" },
  { id := "minimax", name := "MiniMax", usesOAuth := false, envVar? := some "MINIMAX_API_KEY" },
  { id := "cerebras", name := "Cerebras", usesOAuth := false, envVar? := some "CEREBRAS_API_KEY" },
  { id := "groq", name := "Groq", usesOAuth := false, envVar? := some "GROQ_API_KEY" },
  { id := "deepseek", name := "DeepSeek", usesOAuth := false, envVar? := some "DEEPSEEK_API_KEY" },
  { id := "together", name := "Together AI", usesOAuth := false, envVar? := some "TOGETHER_API_KEY" },
  { id := "perplexity", name := "Perplexity", usesOAuth := false, envVar? := some "PERPLEXITY_API_KEY" },
  { id := "cohere", name := "Cohere", usesOAuth := false, envVar? := some "COHERE_API_KEY" },
  { id := "github-copilot", name := "GitHub Copilot", usesOAuth := true, envVar? := some "GITHUB_TOKEN" },
  { id := "amp", name := "Sourcegraph Amp", usesOAuth := false, envVar? := some "AMP_API_KEY" },
  { id := "custom", name := "Custom (OpenAI-compatible)", usesOAuth := false, envVar? := none }
]

def lookupProviderMeta (pType : String) : ProviderTypeMeta :=
  let low := pType.trimAscii.toString.toLower
  (allProviderTypes.find? (fun m => m.id == low)).getD
    { id := low, name := pType, usesOAuth := false, envVar? := none }

def readDataJsonFile (workingDir storeRoot relName : String) : IO JVal := do
  let cands := #[
    s!"{workingDir}/.sandboxed-sh/{relName}",
    s!"{storeRoot}/{relName}"
  ]
  for p in cands do
    let fp := System.FilePath.mk p
    if (← fp.pathExists) then
      if let some raw ← (try some <$> IO.FS.readFile fp catch _ => pure none) then
        if let .ok jv := OrbBin.Json.parse raw then
          return jv
  return .null

private def writeDataJsonFile (workingDir storeRoot relName : String) (jv : JVal) : IO Unit := do
  let dir := if (← (System.FilePath.mk s!"{workingDir}/.sandboxed-sh").pathExists) then
    s!"{workingDir}/.sandboxed-sh"
  else
    storeRoot
  let _ ← writeAtomicPrivate0600 (System.FilePath.mk s!"{dir}/{relName}") ((renderPretty jv) ++ "\n").toUTF8

structure HydratedProvider where
  id              : String
  name            : String
  providerType    : String
  googleProjectId : String
  baseUrl         : String
  apiKey          : String
  hasApiKey       : Bool
  hasOAuth        : Bool
  oauthToken      : String
  oauthFile       : String
  /-- A credential matched to this account independently of legacy display fallbacks. -/
  boundOauthFile  : String := ""
  accountEmail    : String
  enabled         : Bool
  isDefault       : Bool
  priority        : Nat
  useForBackends  : Array String
  customModels    : Array JVal
  rpmLimit?       : Option UInt32
  maxConcurrency? : Option UInt32
  createdAt       : String
  updatedAt       : String
  /-- User who added the account (`''` for operator/legacy rows). -/
  createdByUserId : String := ""
  modelPrefix : String := ""
  /-- Muse Code device credential (`dca_token` in the CLIProxyAPI auth file). The vendor quota
      endpoint accepts this credential, not the minted `access_token`. Never rendered. -/
  deviceToken     : String := ""
  deriving Repr, Inhabited

/-- Muse Code device credential of a row: the matched CLIProxyAPI file's `dca_token`, else the
    legacy `oauth.refresh_token` when that holds a token and not an auth-file name. Empty for
    every other provider type, so no other adapter can pick it up. -/
private def museDeviceToken (providerType : String) (matchedAuth? : Option CliAuthFileInfo)
    (legacyRefresh : String) : String :=
  if providerType.toLower != "muse-code" then ""
  else
    let fromFile := (matchedAuth?.map (·.deviceToken)).getD ""
    let legacy := legacyRefresh.trimAscii.toString
    if !fromFile.isEmpty then fromFile
    else if !legacy.isEmpty && !legacy.endsWith ".json" then legacy
    else ""

def loadHydratedProviders (store : CoreStore) (workingDir : String) : IO (Array HydratedProvider) := do
  let key32? ← loadPrivateKeyBytes? workingDir store.rootDir
  let dbProvs ← listAIProviders store
  let rawLegacy ← readDataJsonFile workingDir store.rootDir "ai_providers.json"
  let legacyJv ← decryptJsonTree key32? rawLegacy
  let legacyArr : Array JVal :=
    match legacyJv with
    | .arr xs => xs
    | .obj _ => (legacyJv.fieldArr? "providers").orElse (fun _ => legacyJv.fieldArr? "items") |>.getD #[]
    | _ => #[]
  let defJv ← readDataJsonFile workingDir store.rootDir "default_provider.json"
  let defaultId := (defJv.fieldStr? "default_provider_id").getD ""
  let backendsJv ← readDataJsonFile workingDir store.rootDir "provider_backends.json"
  let authFiles ← scanCliProxyAuthFiles
  let uniquePrefix := fun (file : CliAuthFileInfo) =>
    if !file.prefixId.isEmpty && !file.prefixId.contains '/' &&
        (authFiles.filter (fun f => f.prefixId == file.prefixId)).size == 1 then file.prefixId else ""

  let nowIso := formatEpochIso8601Utc (← nowEpoch)
  -- Accounts added by a member never inherit the operator's credentials: no instance env-key
  -- fallback and no CLIProxy auth file joined by provider type or email, only by exact row id.
  let memberIds : Array String ← match ← execParamQuery store.missionsDb "SELECT id FROM users WHERE role='member';" #[] with
    | .ok rows => pure ((rows.extract 1 rows.size).filterMap (·[0]?))
    | .error _ => pure #[]

  let mut out : Array HydratedProvider := #[]
  let mut seenIds : Array String := #[]

  for idx in [0:dbProvs.size] do
    let p := dbProvs[idx]!
    seenIds := seenIds.push p.id
    let memberAdded := !p.createdByUserId.isEmpty && memberIds.contains p.createdByUserId
    let leg? := if memberAdded then none else legacyArr.find? (fun j => (j.fieldStr? "id") == some p.id)
    let plainKey ← match ← decryptEnvValue key32? p.apiKey with | .ok s => pure s.trimAscii.toString | .error _ => pure p.apiKey.trimAscii.toString
    let legEmail := (leg?.bind (fun j => j.fieldStr? "account_email")).getD ""
    let legGoogleProj := (leg?.bind (fun j => j.fieldStr? "google_project_id")).getD ""
    let legOauthObj? := leg?.bind (fun j => j.field? "oauth")
     let legRefreshFile := (legOauthObj?.bind (fun o => o.fieldStr? "refresh_token")).getD ""
     let legAuthFile := (leg?.bind (fun j => (j.fieldStr? "cli_proxy_auth_file").orElse (fun _ => j.fieldStr? "auth_file"))).getD ""
     let legSandboxedId := (leg?.bind (fun j => (j.fieldStr? "sandboxed_provider_id").orElse (fun _ => j.fieldStr? "account_id"))).getD ""
    let legAccessTok := (legOauthObj?.bind (fun o => o.fieldStr? "access_token")).getD ""

    let typed := authFiles.filter (fun f => !f.disabled && providerTypeMatchesAuthType p.providerType f.authType)
    let singleton := plainKey == "cli-proxy-managed" && (dbProvs.filter (fun r => r.providerType == p.providerType)).size == 1
    let matchFile := matchCredential? typed p.id memberAdded legAuthFile legRefreshFile legSandboxedId legEmail
    let boundAuth? := matchFile false
    let matchedAuth? := boundAuth?.orElse fun _ => if singleton then matchFile true else none

    let metaInfo := lookupProviderMeta p.providerType
    let envKeyVal ← match metaInfo.envVar? with
      | some ev => if memberAdded then pure "" else pure ((← lookupEnvWithFiles? ev).getD "")
      | none => pure ""
    let effApiKey := if !plainKey.isEmpty && plainKey != "cli-proxy-managed" then plainKey else envKeyVal
    let hasApiKey := !effApiKey.isEmpty
    let hasOAuth := matchedAuth?.isSome || (!legAccessTok.isEmpty) || (p.providerType.toLower == "muse-code" && !legRefreshFile.isEmpty && !legRefreshFile.endsWith ".json") || plainKey == "cli-proxy-managed"
    let effEmail :=
      if !legEmail.isEmpty then legEmail
      else (matchedAuth?.map (·.email)).getD ""
    let effOauthTok :=
      match matchedAuth? with
      | some af => af.accessToken
      | none =>
        if !legAccessTok.isEmpty && legAccessTok != "cli-proxy-managed" then legAccessTok
        else if p.providerType.toLower == "muse-code" && !legRefreshFile.isEmpty && !legRefreshFile.endsWith ".json" then legRefreshFile
        else ""
    let effOauthFile := (matchedAuth?.map (·.fileName)).getD legRefreshFile
    let effDeviceTok := museDeviceToken p.providerType matchedAuth? legRefreshFile

    let bksFromFile : Array String :=
      match backendsJv.fieldArr? p.id with
      | some arr => arr.filterMap JVal.asStr?
      | none =>
        match leg?.bind (fun j => j.fieldArr? "use_for_backends") with
        | some arr => arr.filterMap JVal.asStr?
        | none => #[]

    let cModels : Array JVal := (p.customModels.filter (fun cm =>
      customProviderModelAllowed p.name p.baseUrl cm.id &&
      customProviderModelAllowed p.id p.baseUrl cm.id)).map fun cm =>
      .obj #[
        ("id", .str cm.id),
        ("name", match cm.name? with | some n => .str n | none => .null),
        ("context_limit", match cm.contextLimit? with | some c => JVal.uint64 c.toUInt64 | none => JVal.nat 128000),
        ("output_limit", match cm.outputLimit? with | some o => JVal.uint64 o.toUInt64 | none => JVal.nat 8192)
      ]
    let prio := (leg?.bind (fun j => j.fieldNat? "priority")).getD idx
    let createdStr := (leg?.bind (fun j => j.fieldStr? "created_at")).getD (if p.updatedAt.isEmpty then nowIso else p.updatedAt)
    let updatedStr := if p.updatedAt.isEmpty then createdStr else p.updatedAt

    out := out.push {
      id := p.id
      name := p.name
      providerType := p.providerType
      googleProjectId := legGoogleProj
      baseUrl := p.baseUrl
      apiKey := effApiKey
      hasApiKey := hasApiKey
      hasOAuth := hasOAuth
      oauthToken := effOauthTok
      oauthFile := effOauthFile
      boundOauthFile := (boundAuth?.map (·.fileName)).getD ""
      modelPrefix := (matchedAuth?.map uniquePrefix).getD ""
      accountEmail := effEmail
      enabled := p.enabled
      isDefault := (p.id == defaultId)
      priority := prio
      useForBackends := bksFromFile
      customModels := cModels
      rpmLimit? := p.rpmLimit?
      maxConcurrency? := p.maxConcurrency?
      createdAt := createdStr
      updatedAt := updatedStr
      createdByUserId := p.createdByUserId
      deviceToken := effDeviceTok
    }

  -- Include any entries present in `.sandboxed-sh/ai_providers.json` not yet in SQLite
  for leg in legacyArr do
    let lid := ((leg.fieldStr? "id").getD "").trimAscii.toString
    if !lid.isEmpty && !seenIds.contains lid then
      seenIds := seenIds.push lid
      let pType := ((leg.fieldStr? "provider_type").getD "custom").trimAscii.toString
      let nm := ((leg.fieldStr? "name").getD pType).trimAscii.toString
      let en := (leg.fieldBool? "enabled").getD true
      let bUrl := ((leg.fieldStr? "base_url").getD "").trimAscii.toString
      let aKey := ((leg.fieldStr? "api_key").getD "").trimAscii.toString
      let email := ((leg.fieldStr? "account_email").getD "").trimAscii.toString
      let gProj := ((leg.fieldStr? "google_project_id").getD "").trimAscii.toString
      let oauthObj? := leg.field? "oauth"
      let refFile := (oauthObj?.bind (fun o => o.fieldStr? "refresh_token")).getD ""
      let accTok := (oauthObj?.bind (fun o => o.fieldStr? "access_token")).getD ""
      let typed := authFiles.filter (fun f => !f.disabled && providerTypeMatchesAuthType pType f.authType)
      let authFile := ((leg.fieldStr? "cli_proxy_auth_file").orElse fun _ => leg.fieldStr? "auth_file").getD ""
      let matchedAuth? := matchCredential? typed lid false authFile refFile "" email false
      let hasApi := !aKey.isEmpty && aKey != "cli-proxy-managed"
      let hasOa := matchedAuth?.isSome || !accTok.isEmpty || (pType.toLower == "muse-code" && !refFile.isEmpty && !refFile.endsWith ".json")
      let effLegTok :=
        if !accTok.isEmpty then accTok
        else if pType.toLower == "muse-code" && !refFile.isEmpty && !refFile.endsWith ".json" then refFile
        else ""
      out := out.push {
        id := lid
        name := nm
        providerType := pType
        googleProjectId := gProj
        baseUrl := bUrl
        apiKey := if hasApi then aKey else ""
        hasApiKey := hasApi
        hasOAuth := hasOa
        oauthToken := (matchedAuth?.map (·.accessToken)).getD effLegTok
        oauthFile := (matchedAuth?.map (·.fileName)).getD refFile
        boundOauthFile := (matchedAuth?.map (·.fileName)).getD ""
        modelPrefix := (matchedAuth?.map uniquePrefix).getD ""
        accountEmail := if !email.isEmpty then email else (matchedAuth?.map (·.email)).getD ""
        enabled := en
        isDefault := (lid == defaultId)
        priority := (leg.fieldNat? "priority").getD out.size
        useForBackends := ((leg.fieldArr? "use_for_backends").getD #[]).filterMap JVal.asStr?
        customModels := ((leg.fieldArr? "custom_models").getD #[]).filter (fun cm =>
          let mid := (cm.fieldStr? "id").getD ""
          customProviderModelAllowed nm bUrl mid && customProviderModelAllowed lid bUrl mid)
        rpmLimit? := none
        maxConcurrency? := none
        createdAt := (leg.fieldStr? "created_at").getD nowIso
        updatedAt := (leg.fieldStr? "updated_at").getD nowIso
        deviceToken := museDeviceToken pType matchedAuth? refFile
      }

  -- Any sidecar login may precede creation of a Core provider row. Disabled files with no
  -- matching row stay visible so an operator can see the login and re-enable it; a file that
  -- belongs to a disabled Core row is not duplicated.
  for af in authFiles do
    let pType := if af.authType == "codex" then "openai" else if af.authType == "claude" then "anthropic" else af.authType
    if !out.any (fun hp => hp.oauthFile == af.fileName ||
        (!hp.enabled && hp.id == af.prefixId && !af.prefixId.isEmpty)) then
      out := out.push { (default : HydratedProvider) with
        id := if af.prefixId.isEmpty || af.prefixId == vpnModelPrefix af.fileName || out.any (fun hp => hp.id == af.prefixId) ||
            (authFiles.filter (fun f => f.prefixId == af.prefixId)).size != 1 then fileAccountId pType af.fileName else af.prefixId
        name := (lookupProviderMeta pType).name
        providerType := pType
        hasOAuth := true
        oauthToken := af.accessToken
        oauthFile := af.fileName
        boundOauthFile := af.fileName
        modelPrefix := uniquePrefix af
        accountEmail := af.email
        enabled := !af.disabled
        priority := out.size
        deviceToken := af.deviceToken
      }
  return out.qsort (fun a b => a.priority < b.priority)

/-- Legacy rows can claim the same file. Only an unambiguous binding authorizes routing. -/
def accountRoutingFile (accounts : Array HydratedProvider) (hp : HydratedProvider) : String :=
  if !hp.boundOauthFile.isEmpty && (accounts.filter (fun p => p.oauthFile == hp.boundOauthFile)).size == 1
    then hp.boundOauthFile else ""

def memberProviderDisplayName (hps : Array HydratedProvider) (hp : HydratedProvider) : String := Id.run do
  let metaInfo := lookupProviderMeta hp.providerType
  let sameType := hps.filter (fun p => p.enabled && (p.hasApiKey || p.hasOAuth) && p.providerType.toLower == hp.providerType.toLower)
  if sameType.size ≤ 1 then
    return metaInfo.name
  let idx := (sameType.findIdx? (fun p => p.id == hp.id)).getD 0
  return s!"{metaInfo.name} {idx + 1}"

def renderMemberHydratedProviderJv (hp : HydratedProvider) (displayName : String)
    (userEnabled? : Option Bool := none) (rejected : Bool := false) : JVal := Id.run do
  let metaInfo := lookupProviderMeta hp.providerType
  let hasCreds := hp.hasApiKey || hp.hasOAuth
  let uEn := userEnabled?.getD true
  let effEn := hp.enabled && uEn
  let statusObj : JVal :=
    if hasCreds && rejected then
      .obj #[
        ("type", .str "needs_reauth"),
        ("message", .str "Sign in again: the provider rejected this login")
      ]
    else if hasCreds then
      .obj #[
        ("type", .str "connected"),
        ("message", .str (if hp.hasOAuth then "Connected via OAuth" else "API key configured"))
      ]
    else
      .obj #[
        ("type", .str "needs_auth"),
        ("message", .str "Credentials not configured")
      ]
  .obj #[
    ("id", .str hp.id),
    ("name", .str displayName),
    ("provider_type", .str hp.providerType),
    ("provider_type_name", .str metaInfo.name),
    ("enabled", .bool hp.enabled),
    ("globally_enabled", .bool hp.enabled),
    ("user_enabled", .bool uEn),
    ("effective_enabled", .bool effEn),
    ("has_credentials", .bool hasCreds),
    ("has_api_key", .bool hp.hasApiKey),
    ("has_oauth", .bool hp.hasOAuth),
    ("uses_oauth", .bool metaInfo.usesOAuth),
    ("status", statusObj),
    ("custom_models", .arr hp.customModels)
  ]

def projectMemberProviderUsageJv (jv : JVal) (displayName : String) : JVal :=
  match jv with
  | .obj fields =>
    let scrubbed := fields.filterMap fun (k, v) =>
      if k == "account_email" || k == "account_name" || k == "account" ||
         k == "organization" || k == "organization_id" || k == "google_project_id" ||
         k == "xai_key_name" || k == "xai_team_id" ||
         k == "label" || k == "diagnostic" || k == "verification_url" then
        none
      else if k == "provider_name" || k == "access_profile" then
        some (k, .str displayName)
      else
        some (k, v)
    .obj scrubbed
  | other => other

def renderHydratedProviderJv (hp : HydratedProvider) (userEnabled? : Option Bool := none) (observedRpm? : Option UInt32 := none)
    (rejected : Bool := false) : JVal := Id.run do
  let metaInfo := lookupProviderMeta hp.providerType
  let hasCreds := hp.hasApiKey || hp.hasOAuth
  let authMethods : Array JVal :=
    if metaInfo.usesOAuth && metaInfo.envVar?.isSome then #[.str "oauth", .str "api_key"]
    else if metaInfo.usesOAuth then #[.str "oauth"]
    else #[.str "api_key"]
  let statusObj : JVal :=
    if hasCreds && rejected then
      -- The vendor refused this login on the last usage probe (dead refresh token).
      .obj #[
        ("type", .str "needs_reauth"),
        ("auth_methods", .arr authMethods),
        ("message", .str "Sign in again: the provider rejected this login")
      ]
    else if hasCreds then
      .obj #[
        ("type", .str "connected"),
        ("auth_methods", .arr authMethods),
        ("auth_type", .str (if hp.hasOAuth then "oauth" else "api_key")),
        ("account", if hp.accountEmail.isEmpty then .null else .str hp.accountEmail),
        ("message", .str (if hp.hasOAuth then "Connected via OAuth" else "API key configured"))
      ]
    else
      .obj #[
        ("type", .str "needs_auth"),
        ("auth_methods", .arr authMethods),
        ("message", .str "Credentials not configured")
      ]
  let mut fields : Array (String × JVal) := #[
    ("id", .str hp.id),
    ("name", .str hp.name),
    ("provider_type", .str hp.providerType),
    ("provider_type_name", .str metaInfo.name),
    ("google_project_id", if hp.googleProjectId.isEmpty then .null else .str hp.googleProjectId),
    ("base_url", if hp.baseUrl.isEmpty then .null else .str hp.baseUrl),
    ("has_credentials", .bool hasCreds),
    ("has_api_key", .bool hp.hasApiKey),
    ("has_oauth", .bool hp.hasOAuth),
    ("enabled", .bool hp.enabled),
    ("is_default", .bool hp.isDefault),
    ("uses_oauth", .bool metaInfo.usesOAuth),
    ("env_var", match metaInfo.envVar? with | some ev => .str ev | none => .null),
    ("account_email", if hp.accountEmail.isEmpty then .null else .str hp.accountEmail),
    ("use_for_backends", .arr (hp.useForBackends.map JVal.str)),
    ("custom_models", .arr hp.customModels),
    ("priority", JVal.nat hp.priority),
    ("status", statusObj),
    ("created_at", .str hp.createdAt),
    ("updated_at", .str hp.updatedAt)
  ]
  if let some ue := userEnabled? then
    fields := fields.push ("user_enabled", .bool ue)
  if let some rpm := hp.rpmLimit? then
    fields := fields.push ("rpm_limit", JVal.uint64 rpm.toUInt64)
  if let some conc := hp.maxConcurrency? then
    fields := fields.push ("max_concurrency", JVal.uint64 conc.toUInt64)
  if let some obs := observedRpm? then
    fields := fields.push ("observed_rpm", JVal.uint64 obs.toUInt64)
  .obj fields

/-- Whether `callerUserId` added `hp` (never true for operator/legacy rows with no creator). -/
def providerAddedBy (hp : HydratedProvider) (callerUserId : String) : Bool :=
  !hp.createdByUserId.isEmpty && hp.createdByUserId == callerUserId

/-- Render one provider for the caller: admins and the member who added the account get the
    full (credential-free) view plus who added it; other members get the reduced view. -/
def renderHydratedProviderForCaller (hps : Array HydratedProvider) (hp : HydratedProvider)
    (effAdmin : Bool) (callerUserId : String) (usernames : Array (String × String))
    (userEnabled? : Option Bool := none) (observedRpm? : Option UInt32 := none)
    (rejected : Bool := false) : JVal :=
  if effAdmin || providerAddedBy hp callerUserId then
    let base := renderHydratedProviderJv hp userEnabled? (if effAdmin then observedRpm? else none) rejected
    let uname := (usernames.find? (·.1 == hp.createdByUserId)).map Prod.snd
    let base := base.setField "added_by_me" (.bool (providerAddedBy hp callerUserId))
    if hp.createdByUserId.isEmpty then base
    else (base.setField "created_by_user_id" (.str hp.createdByUserId)).setField "created_by_username"
      (match uname with | some u => .str u | none => .null)
  else
    (renderMemberHydratedProviderJv hp (memberProviderDisplayName hps hp) userEnabled? rejected).setField
      "added_by_me" (.bool false)

/-! ## Provider Subscription & Rate-Limit Usage (`GET /api/ai/providers/usage` & `/:id/usage`) -/

private def findHeaderCI? (hdrs : Array (String × String)) (name : String) : Option String :=
  let nl := name.toLower
  (hdrs.find? (fun (k, _) => k.toLower == nl)).map Prod.snd

private def buildOptimizeWindow
    (key label metric source : String)
    (pctUsed : String)
    (windowSecs : Nat)
    (resetAt? : Option String) : JVal :=
  let usedNat := ((pctUsed.splitOn ".").headD "0").toNat?.getD 0
  let remNat := if usedNat >= 100 then 0 else 100 - usedNat
  .obj #[
    ("key", .str key),
    ("label", .str label),
    ("metric", .str metric),
    ("source", .str source),
    ("pct_used", .num pctUsed),
    ("pct_remaining", JVal.nat remNat),
    ("limit", .null),
    ("remaining", .null),
    ("used", .null),
    ("window_seconds", JVal.nat windowSecs),
    ("reset_at", match resetAt? with | some r => if r.isEmpty then .null else .str r | none => .null),
    ("reset_in_seconds", .null)
  ]

/-- Pick the optimize window key with the lowest `pct_remaining` (matching `usage_optimize.rs`). -/
def selectPrimaryOptimizeWindow (windows : Array JVal) : JVal := Id.run do
  let mut bestKey? : Option String := none
  let mut bestRem : Nat := 1000000
  for w in windows do
    let some k := w.fieldStr? "key" | continue
    let rem := (w.fieldNat? "pct_remaining").getD 100
    if bestKey?.isNone || rem < bestRem then
      bestKey? := some k
      bestRem := rem
  match bestKey? with
  | some k => .str k
  | none => .null

/-- Match the historical serde `as_i64` reset contract: integer JSON only,
    including zero/negative values, without wrapping values outside signed i64. -/
private def codexResetEpoch? (window : JVal) : Option Int := do
  let epoch ← window.fieldInt? "reset_at"
  if epoch < (-9223372036854775808 : Int) then none
  else if epoch > (9223372036854775807 : Int) then none
  else some epoch

/-- Derive the `(key, label)` for a Codex optimize window from its reported duration in seconds,
    matching the actual window length rather than assuming `primary = 5h`. -/
private def codexOptimizeWindowKeyLabel (winSecs : Nat) (fallbackKey fallbackLabel : String) : String × String :=
  let mins := winSecs / 60
  if mins == 0 then (fallbackKey, fallbackLabel)
  else if mins == 10080 then ("7d", "7-day")
  else if mins >= 1440 && mins % 1440 == 0 then
    let d := mins / 1440
    (s!"{d}d", s!"{d}-day")
  else if mins >= 60 && mins % 60 == 0 then
    let h := mins / 60
    (s!"{h}h", s!"{h}-hour")
  else
    (s!"{mins}m", s!"{mins}-minute")

/-- Extract an optional human-readable window/limit name when upstream `wham/usage` provides one. -/
private def codexWindowUpstreamLabel? (w : JVal) : Option String :=
  let tryKey (k : String) : Option String :=
    (w.fieldStr? k).map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  tryKey "limit_name" <|> tryKey "label" <|> tryKey "name" <|> tryKey "title" <|> tryKey "window_name"

/-- The production wham projection, kept pure so wire fixtures need no vendor calls.
    Scalar Codex fields and optimize-window fields have separate client contracts. -/
def projectCodexUsage (wham : JVal) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[
    ("codex_plan_type", .str ((wham.fieldStr? "plan_type").getD "pro")),
    ("codex_source", .str "usage")]
  let mut windows : Array JVal := #[]
  if let some rl := wham.field? "rate_limit" then
    let mut primaryBaseKey? : Option String := none
    let mut primaryBaseLabel? : Option String := none
    if let some pw := rl.field? "primary_window" then
      let usedPct := match pw.field? "used_percent" with | some (.num n) => n | _ => "0"
      let resetEpoch? := codexResetEpoch? pw
      let resetSec := (resetEpoch?.map (fun epoch => epoch.toNat.toUInt64)).getD 0
      let resetIso := if resetSec > 0 then formatEpochIso8601Utc resetSec else ""
      let winSecs := (pw.fieldNat? "limit_window_seconds").getD 18000
      fields := fields.push ("codex_primary_used_percent", .num usedPct)
      fields := fields.push ("codex_primary_window_minutes", JVal.nat (winSecs / 60))
      if let some epoch := resetEpoch? then
        fields := fields.push ("codex_primary_reset_at", JVal.int epoch)
      let upstreamLbl? := codexWindowUpstreamLabel? pw
      if let some lbl := upstreamLbl? then
        fields := fields.push ("codex_primary_window_label", .str lbl)
      let (baseKey, baseLabel) := codexOptimizeWindowKeyLabel winSecs "primary" "Primary"
      primaryBaseKey? := some baseKey
      primaryBaseLabel? := some baseLabel
      let optLabel := upstreamLbl?.getD baseLabel
      windows := windows.push (buildOptimizeWindow baseKey optLabel "used_pct" "codex_wham" usedPct winSecs (some resetIso))
    if let some sw := rl.field? "secondary_window" then
      let usedPct := match sw.field? "used_percent" with | some (.num n) => n | _ => "0"
      let resetEpoch? := codexResetEpoch? sw
      let resetSec := (resetEpoch?.map (fun epoch => epoch.toNat.toUInt64)).getD 0
      let resetIso := if resetSec > 0 then formatEpochIso8601Utc resetSec else ""
      let winSecs := (sw.fieldNat? "limit_window_seconds").getD 604800
      fields := fields.push ("codex_secondary_used_percent", .num usedPct)
      fields := fields.push ("codex_secondary_window_minutes", JVal.nat (winSecs / 60))
      if let some epoch := resetEpoch? then
        fields := fields.push ("codex_secondary_reset_at", JVal.int epoch)
      let upstreamLbl? := codexWindowUpstreamLabel? sw
      if let some lbl := upstreamLbl? then
        fields := fields.push ("codex_secondary_window_label", .str lbl)
      let (baseKey, baseLabel) := codexOptimizeWindowKeyLabel winSecs "secondary" "Secondary"
      let sameKey := primaryBaseKey? == some baseKey
      let sameLabel := primaryBaseLabel? == some baseLabel
      let optKey := if sameKey then s!"{baseKey}_secondary" else baseKey
      let optLabel := match upstreamLbl? with
        | some lbl => lbl
        | none => if sameLabel then s!"{baseLabel} (secondary)" else baseLabel
      windows := windows.push (buildOptimizeWindow optKey optLabel "used_pct" "codex_wham" usedPct winSecs (some resetIso))
  return (fields, windows, selectPrimaryOptimizeWindow windows)

/-- A JSON fraction (`1`, `0.9972415`, `2.5e-05`) as millionths, clamped to `[0, 1_000_000]`. -/
def antigravityFractionMicros? (raw : String) : Option Nat := do
  let s := raw.trimAscii.toString
  if s.startsWith "-" then return 0
  let (mant, exp) ← match s.splitOn "e" with
    | [m] => match m.splitOn "E" with
      | [m'] => some (m', (0 : Int))
      | [m', e] => (String.toInt? e).map (m', ·)
      | _ => none
    | [m, e] => (String.toInt? e).map (m, ·)
    | _ => none
  let (whole, frac) ← match mant.splitOn "." with
    | [w] => some (w, "")
    | [w, f] => some (w, f)
    | _ => none
  let digits ← (whole ++ frac).toNat?
  let shift : Int := 6 + exp - frac.length
  let micros := if shift ≥ 0 then digits * 10 ^ shift.toNat else digits / 10 ^ (-shift).toNat
  return min micros 1000000

/-- Used share of a remaining fraction, in tenths of a percent (`1000` = 100%). -/
def antigravityUsedTenths (remainingMicros : Nat) : Nat :=
  (1000000 - min remainingMicros 1000000 + 500) / 1000

private def antigravityWindowJv (label : String) (usedTenths : Nat) (reset? : Option UInt64) : JVal :=
  let base := #[("label", .str label), ("used_percent", .num s!"{usedTenths / 10}.{usedTenths % 10}")]
  .obj (match reset? with | some r => base.push ("reset_at", .num (toString r)) | none => base)

private def antigravityReset? (bucket : JVal) : Option UInt64 :=
  (bucket.fieldStr? "resetTime").bind parseIso8601EpochU64?

private def antigravityRemaining? (bucket : JVal) : Option Nat :=
  match bucket.field? "remainingFraction" with
  | some (.num raw) => antigravityFractionMicros? raw
  | _ => none

private def antigravityGroupLabel (group : JVal) : String :=
  let ids := ((group.fieldArr? "buckets").getD #[]).filterMap (·.fieldStr? "bucketId")
  if ids.any (·.startsWith "gemini-") then "Gemini"
  else if ids.any (·.startsWith "3p-") then "Claude & GPT"
  else
    let n := (group.fieldStr? "displayName").getD ""
    let n := if n.endsWith " models" || n.endsWith " Models" then (n.dropEnd 7).toString else n
    if n.isEmpty then "Models" else n

/-- `retrieveUserQuotaSummary`: one window per group and quota period (5h, daily, weekly). -/
def parseAntigravitySummary (payload : JVal) : Array JVal := Id.run do
  let rank (b : JVal) : Nat := match b.fieldStr? "window" with
    | some "5h" => 0 | some "daily" => 1 | some "weekly" => 2 | _ => 3
  let mut out : Array JVal := #[]
  for group in (payload.fieldArr? "groups").getD #[] do
    let name := antigravityGroupLabel group
    let buckets := ((group.fieldArr? "buckets").getD #[]).toList.mergeSort (fun a b => rank a ≤ rank b)
    for bucket in buckets do
      -- Google omits a zero remaining fraction: a bucket with a reset but no figure is spent.
      let some remaining := (antigravityRemaining? bucket).orElse
          (fun _ => (antigravityReset? bucket).map (fun _ => 0)) | continue
      let window := match (bucket.fieldStr? "window").getD "" with
        | "weekly" => "Weekly"
        | "daily" => "Daily"
        | other => other
      if window.isEmpty then continue
      out := out.push (antigravityWindowJv s!"{name} · {window}" (antigravityUsedTenths remaining) (antigravityReset? bucket))
  return out

/-- Gemini quota from `retrieveUserQuota` (`buckets` or `models.*.quotaInfo`) when the summary
    has no Gemini group: the tightest remaining fraction, named 5h or Weekly from its reset. -/
def antigravityGeminiWindow? (payload : JVal) (nowSec : UInt64) : Option JVal := Id.run do
  let isGemini (id : String) : Bool :=
    let m := id.toLower
    ((m.splitOn "gemini").length > 1 && (m.splitOn "carbon").length == 1) || m.startsWith "agy-demo"
  let mut entries : Array (String × JVal) := #[]
  for b in (payload.fieldArr? "buckets").getD #[] do
    if let some id := b.fieldStr? "modelId" then entries := entries.push (id, b)
  if let some (.obj models) := payload.field? "models" then
    for (id, m) in models do
      entries := entries.push (id, (m.field? "quotaInfo").getD .null)
  let mut remaining : Option Nat := none
  let mut reset : Option UInt64 := none
  for (id, info) in entries do
    if !isGemini id then continue
    let resetAt := antigravityReset? info
    let frac? : Option Nat := match info.field? "remainingFraction", resetAt with
      | some (.num raw), _ => antigravityFractionMicros? raw
      | _, some _ => some 0
      | _, none => none
    let some frac := frac? | continue
    remaining := some (match remaining with | some r => min r frac | none => frac)
    if frac < 1000000 then
      reset := match reset, resetAt with
        | some a, some b => some (min a b)
        | a, b => a <|> b
  let some rem := remaining | return none
  let window := match reset with
    | some r => if r > nowSec + 5 * 3600 + 600 then "Weekly" else "5h"
    | none => "5h"
  return some (antigravityWindowJv s!"Gemini · {window}" (antigravityUsedTenths rem) reset)

private def antigravityFamily? (model : String) : Option String :=
  let m := model.toLower
  if (m.splitOn "claude").length > 1 then some "Claude"
  else if (m.splitOn "gpt").length > 1 then some "GPT-OSS"
  else if (m.splitOn "image").length > 1 then some "Image"
  else if (m.splitOn "gemini").length > 1 && (m.splitOn "pro").length > 1 then some "Gemini Pro"
  else if (m.splitOn "gemini").length > 1 && (m.splitOn "flash").length > 1 then some "Gemini Flash"
  else if m.startsWith "agy-" then some "Gemini Agent"
  else none

/-- `retrieveUserQuota` fallback: per-model buckets merged into one window per model family.
    Google omits a zero remaining fraction, so a bucket with a reset but no figure is spent. -/
def parseAntigravityQuota (payload : JVal) : Array JVal := Id.run do
  let mut wins : Array (String × Nat × Option UInt64) := #[]
  for bucket in (payload.fieldArr? "buckets").getD #[] do
    let some label := (bucket.fieldStr? "modelId").bind antigravityFamily? | continue
    let reset := antigravityReset? bucket
    let remaining? : Option Nat := match bucket.field? "remainingFraction", reset with
      | some (.num raw), _ => antigravityFractionMicros? raw
      | _, some _ => some 0
      | _, none => none
    let some remaining := remaining? | continue
    let used := antigravityUsedTenths remaining
    if reset.isNone && used == 0 then continue
    match wins.findIdx? (·.1 == label) with
    | some i =>
      let (_, u, r) := wins[i]!
      let r' := match r, reset with
        | some a, some b => some (min a b)
        | a, b => a <|> b
      wins := wins.set! i (label, max u used, r')
    | none => wins := wins.push (label, used, reset)
  return wins.map fun (l, u, r) => antigravityWindowJv l u r

/-- `seven_day_<model>` objects of Anthropic's OAuth usage (`{utilization, resets_at}`, percent)
    as `{label: "<Model> · Weekly", used_percent, reset_at?}`. Unknown model keys pass through,
    so a newly metered model appears without a client change. -/
def anthropicModelWindows (usage : JVal) : Array JVal := Id.run do
  let .obj fields := usage | return #[]
  let mut out : Array JVal := #[]
  for (key, v) in fields do
    if !key.startsWith "seven_day_" || key == "seven_day_oauth_apps" then continue
    let some (.num pct) := v.field? "utilization" | continue
    let model := (key.drop 10).toString.replace "_" " "
    let label := (model.capitalize) ++ " · Weekly"
    let base := #[("label", JVal.str label), ("used_percent", JVal.num pct)]
    let reset? := (v.fieldStr? "resets_at").bind parseIso8601EpochU64?
    out := out.push (.obj (match reset? with
      | some r => base.push ("reset_at", JVal.num (toString r))
      | none => base))
  return out

/-- Parse numeric or numeric-string JSON value into raw number string. -/
private def jvalNumRaw? (v : JVal) : Option String :=
  match v with
  | .num raw =>
    let t := raw.trimAscii.toString
    if t.isEmpty then none else some t
  | .str s =>
    let t := s.trimAscii.toString
    if t.isEmpty then none
    else if t.toInt?.isSome then some t
    else
      -- A vendor string is only passed on as a JSON number when it is one.
      match t.splitOn "." with
      | [whole, frac] =>
        if whole.toInt?.isSome && !frac.isEmpty && frac.all Char.isDigit then some t else none
      | _ => none
  | _ => none

/-- Parse numeric, numeric-string, or `{val: ...}` JSON value into Nat. -/
private def jvalNatFlex? (v : JVal) : Option Nat :=
  match v with
  | .num raw => ((raw.trimAscii.toString.splitOn ".").headD "").toNat?
  | .str s => ((s.trimAscii.toString.splitOn ".").headD "").toNat?
  | .obj _ => (v.field? "val").bind fun inner =>
    match inner with
    | .num r => ((r.trimAscii.toString.splitOn ".").headD "").toNat?
    | .str r => ((r.trimAscii.toString.splitOn ".").headD "").toNat?
    | _ => none
  | _ => none

/-- Parse epoch seconds from integer/float (seconds or ms if > 10^11), numeric string, or RFC3339 string. -/
private def jvalEpochSec? (v : JVal) : Option UInt64 :=
  match v with
  | .num raw =>
    let n? := ((raw.trimAscii.toString.splitOn ".").headD "").toNat?
    n?.bind fun n =>
      if n == 0 then none
      else if n > 100000000000 then some (n / 1000).toUInt64
      else some n.toUInt64
  | .str s =>
    let t := s.trimAscii.toString
    if let some n := t.toNat? then
      if n == 0 then none
      else if n > 100000000000 then some (n / 1000).toUInt64
      else some n.toUInt64
    else
      parseIso8601EpochU64? t
  | _ => none

/-- Format tenths of a percent (`375` -> `"37.5"`, `750` -> `"75"`). -/
private def formatTenthsPct (tenths : Nat) : String :=
  let clamped := min tenths 1000
  if clamped % 10 == 0 then toString (clamped / 10)
  else s!"{clamped / 10}.{clamped % 10}"

/-- Parse a number string (`"37.5"`, `"75"`, `"0.42"`) into tenths (`375`, `750`, `4`). -/
private def parseNumTenths? (raw : String) : Option Nat := do
  let s := raw.trimAscii.toString
  if s.startsWith "-" then return 0
  match s.splitOn "." with
  | [w] =>
    let wn ← w.toNat?
    return wn * 10
  | [w, f] =>
    let wn ← (if w.isEmpty then some 0 else w.toNat?)
    let f1 := (f.take 1).toString
    let fn ← (if f1.isEmpty then some 0 else f1.toNat?)
    return wn * 10 + fn
  | _ => none

/-- Pure Muse Code usage projector (`POST https://api.meta.ai/muse-code/key`).
    Never fabricates `muse_subscription_active = true` or 0% windows when idle. -/
def projectMuseCodeUsage (body : JVal) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[]
  let mut windows : Array JVal := #[]
  if let some tier := (body.fieldStr? "subs_tier_name").map (·.trimAscii.toString) then
    if !tier.isEmpty then
      fields := fields.push ("muse_plan", .str tier)
  if let some active := (body.fieldBool? "is_subs_active").orElse (fun _ => body.fieldBool? "subscription_active") then
    fields := fields.push ("muse_subscription_active", .bool active)
  let usage := body.fieldOrNull "subs_usage"
  let mut hasAnyWindow := false
  if let some w5 := usage.field? "window" then
    if let some pctRaw := (w5.field? "used_percent").bind jvalNumRaw? then
      hasAnyWindow := true
      fields := fields.push ("muse_5h_used_percent", .num pctRaw)
      let resetSec? := (w5.field? "resets_at").bind jvalEpochSec?
      if let some r := resetSec? then
        fields := fields.push ("muse_5h_reset", JVal.uint64 r)
      let resetIso? := resetSec?.map formatEpochIso8601Utc
      windows := windows.push (buildOptimizeWindow "muse_5h" "5-hour" "tokens" "muse_code" pctRaw 18000 resetIso?)
  if let some ww := usage.field? "weekly" then
    if let some pctRaw := (ww.field? "used_percent").bind jvalNumRaw? then
      hasAnyWindow := true
      fields := fields.push ("muse_weekly_used_percent", .num pctRaw)
      let resetSec? := (ww.field? "resets_at").bind jvalEpochSec?
      if let some r := resetSec? then
        fields := fields.push ("muse_weekly_reset", JVal.uint64 r)
      let resetIso? := resetSec?.map formatEpochIso8601Utc
      windows := windows.push (buildOptimizeWindow "muse_weekly" "weekly" "tokens" "muse_code" pctRaw 604800 resetIso?)
  if !hasAnyWindow then
    fields := fields.push ("usage_note", .str "No Muse Code usage in the current window.")
  return (fields, windows, selectPrimaryOptimizeWindow windows)

private def formatKimiMembershipLevel (raw : String) : Option String :=
  let t := raw.trimAscii.toString
  if t.isEmpty then none
  else
    let stripped := if t.toUpper.startsWith "LEVEL_" then (t.drop 6).toString else t
    let words := (stripped.replace "_" " ").splitOn " " |>.filter (!·.isEmpty)
    if words.isEmpty then none
    else some (String.intercalate " " (words.map fun w => w.toLower.capitalize))

/-- Length of a Kimi `window` object in minutes (`duration` + `timeUnit`); an unknown unit counts as hours. -/
private def kimiWindowMinutes? (win : JVal) : Option Nat :=
  ((win.field? "duration").bind jvalNatFlex?).map fun dur =>
    let unit := ((win.fieldStr? "timeUnit").orElse (fun _ => win.fieldStr? "time_unit") |>.getD "").toUpper
    let has (s : String) : Bool := (unit.splitOn s).length > 1
    if has "MINUTE" then dur
    else if has "HOUR" then dur * 60
    else if has "DAY" then dur * 1440
    else if has "WEEK" then dur * 10080
    else dur * 60

private def classifyKimiMinutes (minutes : Nat) : String :=
  if 294 < minutes && minutes < 306 then "5h"
  else if minutes ≥ 8640 then "weekly"
  else "other"

private def classifyKimiLabel (label : String) : String :=
  let l := label.toLower
  let has (s : String) : Bool := (l.splitOn s).length > 1
  if has "5h" || has "5-hour" || has "5 hour" || has "300m" || has "five" then "5h"
  else if l == "all" || has "week" || has "7d" || has "7-day" then "weekly"
  else "other"

/-- `"5h"`, `"weekly"` or `"other"`: the entry's `window` length when it has one, else its names. -/
private def classifyKimiEntry (entry : JVal) (label : String) : String :=
  match (entry.field? "window").bind kimiWindowMinutes? with
  | some minutes => classifyKimiMinutes minutes
  | none =>
    let name := ((entry.fieldStr? "name").orElse (fun _ => (entry.fieldStr? "type").orElse (fun _ => entry.fieldStr? "model_name")) |>.getD "")
    let kind := classifyKimiLabel name
    if kind != "other" then kind else classifyKimiLabel label

/-- Label of `limits[idx]` from its `window`; never a guessed 5h/weekly name. -/
private def kimiLimitLabel (item : JVal) (idx : Nat) : String :=
  let fallback := s!"Limit {idx + 1}"
  match item.field? "window" with
  | none => fallback
  | some win =>
    match kimiWindowMinutes? win with
    | none => fallback
    | some minutes =>
      let kind := classifyKimiMinutes minutes
      if kind == "5h" then "5h"
      else if kind == "weekly" then "Weekly"
      else
        let dur := ((win.field? "duration").bind jvalNumRaw?).getD ""
        let unit := ((win.fieldStr? "timeUnit").orElse (fun _ => win.fieldStr? "time_unit") |>.getD "").trimAscii.toString
        (s!"{dur} {unit}").trimAscii.toString

/-- One Kimi quota window as the vendor reported it. Absent values stay absent. -/
private structure KimiWindow where
  label       : String
  kind        : String := "other"
  used?       : Option String := none
  limit?      : Option String := none
  remaining?  : Option String := none
  usedTenths? : Option Nat := none
  reset?      : Option UInt64 := none
  deriving Inhabited

/-- Read one window from a `data[]` item, the `usage` object or a `limits[]` entry (its `detail`
    when present). `none` when it reports no used, limit, remaining or percentage value. -/
private def kimiWindowFrom? (entry : JVal) (defaultLabel : String) (nowSec : UInt64) : Option KimiWindow := Id.run do
  let detail := (entry.field? "detail").getD entry
  let raw (keys : Array String) : Option String := keys.findSome? fun k => (detail.field? k).bind jvalNumRaw?
  let nat (keys : Array String) : Option Nat := keys.findSome? fun k => (detail.field? k).bind jvalNatFlex?
  let limitKeys := #["limit", "limit_amount", "total"]
  let remainingKeys := #["remaining", "left", "remain"]
  let usedKeys := #["used", "used_amount", "consumed", "current"]
  let derivedUsed? : Option Nat :=
    match nat limitKeys, nat remainingKeys with
    | some lim, some rem => some (lim - rem)
    | _, _ => none
  let usedNat? := (nat usedKeys).orElse fun _ => derivedUsed?
  let used? := (raw usedKeys).orElse fun _ => derivedUsed?.map toString
  let reported? := ((raw #["used_percent", "usedPercent", "percentage", "percent"]).bind parseNumTenths?).map (min · 1000)
  let usedTenths? : Option Nat := reported?.orElse fun _ =>
    match usedNat?, nat limitKeys with
    | some u, some lim => if lim > 0 then some (min ((u * 1000 + lim / 2) / lim) 1000) else none
    | _, _ => none
  if used?.isNone && (raw limitKeys).isNone && (raw remainingKeys).isNone && usedTenths?.isNone then return none
  let named? := #["name", "title", "model_name"].findSome? fun k =>
    ((detail.fieldStr? k).map (·.trimAscii.toString)).filter (fun s => !s.isEmpty && s != "all")
  let reset? : Option UInt64 :=
    ((detail.field? "resetTime").orElse fun _ =>
     (detail.field? "reset_at").orElse fun _ =>
     (detail.field? "reset_time").orElse fun _ =>
     (detail.field? "nextResetTime").orElse fun _ =>
     (entry.field? "resetTime").orElse fun _ =>
     (entry.field? "reset_at").orElse fun _ =>
     entry.field? "reset_time").bind jvalEpochSec?
    <|> ((detail.fieldNat? "reset_in").orElse (fun _ => entry.fieldNat? "reset_in")).map (fun s => nowSec + s.toUInt64)
  return some {
    label := named?.getD defaultLabel
    used? := used?
    limit? := raw limitKeys
    remaining? := raw remainingKeys
    usedTenths? := usedTenths?
    reset? := reset?
  }

private def kimiWindowJv (w : KimiWindow) : JVal := Id.run do
  let mut fields : Array (String × JVal) := #[("label", .str w.label)]
  if let some v := w.used? then fields := fields.push ("used", .num v)
  if let some v := w.limit? then fields := fields.push ("limit", .num v)
  if let some v := w.remaining? then fields := fields.push ("remaining", .num v)
  if let some tenths := w.usedTenths? then
    fields := fields.push ("used_percent", .num (formatTenthsPct tenths))
    fields := fields.push ("remaining_percent", .num (formatTenthsPct (1000 - min tenths 1000)))
  if let some r := w.reset? then fields := fields.push ("reset_at", JVal.uint64 r)
  return .obj fields

/-- Pure Kimi Coding usage projector (`GET https://api.kimi.com/coding/v1/usages`).
    Reads both payload families: a `data[]` list of windows, or `usage` (the weekly window) plus
    `limits[]`. Every reported window is kept in `kimi_windows` with the vendor's own label; the
    first 5-hour and first weekly window also fill the `kimi_5h_*` / `kimi_weekly_*` scalars and
    lead the list. A window that is neither is never renamed 5h or weekly. -/
def projectKimiUsage (body : JVal) (nowSec : UInt64 := 0) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[]
  let mut optWins : Array JVal := #[]
  let plan? : Option String :=
    (((body.field? "user").bind (·.field? "membership")).bind (·.fieldStr? "level")).bind formatKimiMembershipLevel
    <|> (body.fieldStr? "plan").orElse (fun _ => (body.fieldStr? "tier").orElse (fun _ => body.fieldStr? "plan_type"))
    <|> (body.field? "data").bind (·.fieldStr? "plan")
  if let some p := plan? then
    if !p.trimAscii.isEmpty then
      fields := fields.push ("kimi_plan", .str p.trimAscii.toString)

  let mut rows : Array KimiWindow := #[]
  match body.field? "data" with
  | some (.arr items) =>
    for item in items do
      let fallback := if item.fieldStr? "model_name" == some "all" then "Weekly" else "Quota"
      if let some w := kimiWindowFrom? item fallback nowSec then
        rows := rows.push { w with kind := classifyKimiEntry item w.label }
  | _ =>
    if let some usage := body.field? "usage" then
      if let some w := kimiWindowFrom? usage "Weekly" nowSec then
        rows := rows.push { w with kind := "weekly" }
    let limits := (body.fieldArr? "limits").getD #[]
    for idx in [0:limits.size] do
      let item := limits[idx]!
      let label := kimiLimitLabel item idx
      if let some w := kimiWindowFrom? item label nowSec then
        rows := rows.push { w with kind := classifyKimiEntry item label }

  let fiveIdx? := rows.findIdx? (·.kind == "5h")
  let weeklyIdx? := rows.findIdx? (·.kind == "weekly")
  let mut ordered : Array KimiWindow := #[]

  if let some w := fiveIdx?.bind (rows[·]?) then
    ordered := ordered.push w
    if let some tenths := w.usedTenths? then
      let usedStr := formatTenthsPct tenths
      fields := fields.push ("kimi_5h_used_percent", .num usedStr)
      fields := fields.push ("kimi_5h_remaining_percent", .num (formatTenthsPct (1000 - min tenths 1000)))
      optWins := optWins.push (buildOptimizeWindow "kimi_5h" "5-hour" "requests" "kimi_usage" usedStr 18000 (w.reset?.map formatEpochIso8601Utc))
    if let some r := w.reset? then
      fields := fields.push ("kimi_5h_reset", JVal.uint64 r)

  if let some w := weeklyIdx?.bind (rows[·]?) then
    ordered := ordered.push w
    if let some tenths := w.usedTenths? then
      let usedStr := formatTenthsPct tenths
      fields := fields.push ("kimi_weekly_used_percent", .num usedStr)
      fields := fields.push ("kimi_weekly_remaining_percent", .num (formatTenthsPct (1000 - min tenths 1000)))
      optWins := optWins.push (buildOptimizeWindow "kimi_weekly" "weekly" "requests" "kimi_usage" usedStr 604800 (w.reset?.map formatEpochIso8601Utc))
    if let some r := w.reset? then
      fields := fields.push ("kimi_weekly_reset", JVal.uint64 r)

  for idx in [0:rows.size] do
    if some idx != fiveIdx? && some idx != weeklyIdx? then
      ordered := ordered.push rows[idx]!

  if !ordered.isEmpty then
    fields := fields.push ("kimi_windows", .arr (ordered.map kimiWindowJv))
  return (fields, optWins, selectPrimaryOptimizeWindow optWins)

/-- Pure xAI / Grok billing + settings projector. -/
def projectXaiBillingUsage (billing : JVal) (settings? : Option JVal := none) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[]
  let mut optWins : Array JVal := #[]
  let cfg := (billing.field? "config").getD billing
  let plan? : Option String :=
    (settings?.bind (fun s => (s.fieldStr? "subscription_tier_display").orElse (fun _ => (s.fieldStr? "plan").orElse (fun _ => s.fieldStr? "tier"))))
    <|> (billing.fieldStr? "subscription_tier_display").orElse (fun _ => (billing.fieldStr? "plan").orElse (fun _ => billing.fieldStr? "tier"))
    <|> (cfg.fieldStr? "subscription_tier_display")
  if let some p := plan? then
    if !p.trimAscii.isEmpty then
      fields := fields.push ("xai_plan", .str p.trimAscii.toString)

  let period := (cfg.field? "currentPeriod").orElse (fun _ => (billing.field? "currentPeriod").orElse (fun _ => billing.field? "billingCycle")) |>.getD cfg
  let startSec? := ((period.field? "start").orElse (fun _ => period.field? "billingPeriodStart")).bind jvalEpochSec?
  let endSec? := ((period.field? "end").orElse (fun _ => (period.field? "billingPeriodEnd").orElse (fun _ => cfg.field? "billingPeriodEnd"))).bind jvalEpochSec?

  let spanSecs? : Option UInt64 :=
    match startSec?, endSec? with
    | some s, some e => if e > s then some (e - s) else none
    | _, _ => none

  let creditLabel : String :=
    match spanSecs? with
    | some span =>
      if span >= 5 * 86400 && span <= 9 * 86400 then "Weekly"
      else if span >= 20 * 86400 && span <= 35 * 86400 then "Monthly"
      else "Credits"
    | none => "Credits"

  let onDemandUsed? := ((cfg.field? "onDemandUsed").orElse (fun _ => billing.field? "onDemandUsed")).bind jvalNumRaw?
  let onDemandCap? := ((cfg.field? "onDemandCap").orElse (fun _ => billing.field? "onDemandCap")).bind jvalNumRaw?
  if let some u := onDemandUsed? then fields := fields.push ("xai_on_demand_used", .num u)
  if let some c := onDemandCap? then fields := fields.push ("xai_on_demand_cap", .num c)

  let explicitPct? : Option String :=
    ((cfg.field? "creditUsagePercent").orElse fun _ =>
     (billing.field? "creditUsagePercent").orElse fun _ =>
     (cfg.field? "used_percent").orElse fun _ =>
     billing.field? "used_percent").bind jvalNumRaw?

  let computedPct? : Option String := Id.run do
    if let (some u, some c) := ((cfg.field? "onDemandUsed").bind jvalNatFlex?, (cfg.field? "onDemandCap").bind jvalNatFlex?) then
      if c > 0 && explicitPct?.isNone then
        return some (formatTenthsPct ((u * 1000 + c / 2) / c))
    if let (some u, some lim) := (((billing.field? "usage").bind (·.field? "totalUsed")).bind jvalNatFlex?, (billing.field? "monthlyLimit").bind jvalNatFlex?) then
      if lim > 0 then
        return some (formatTenthsPct ((u * 1000 + lim / 2) / lim))
    if endSec?.isSome then
      return some "0"
    return none

  if let some pctRaw := explicitPct? <|> computedPct? then
    let tenths := (parseNumTenths? pctRaw).getD 0
    let remStr := formatTenthsPct (1000 - min tenths 1000)
    let winSecs := (spanSecs?.map (·.toNat)).getD 2592000
    fields := fields.push ("xai_credit_label", .str creditLabel)
    fields := fields.push ("xai_credit_used_percent", .num pctRaw)
    fields := fields.push ("xai_credit_remaining_percent", .num remStr)
    if let some r := endSec? then
      fields := fields.push ("xai_credit_reset", JVal.uint64 r)
    if let some sp := spanSecs? then
      fields := fields.push ("xai_credit_window_seconds", JVal.uint64 sp)
    optWins := optWins.push (buildOptimizeWindow "xai_credits" creditLabel.toLower "credits" "xai" pctRaw winSecs (endSec?.map formatEpochIso8601Utc))

  return (fields, optWins, selectPrimaryOptimizeWindow optWins)

/-- Pure MiniMax Coding Plan / Token Plan usage projector (`GET https://www.minimax.io/v1/api/openplatform/coding_plan/remains`).
    Note: MiniMax API's `current_interval_usage_count` and `current_weekly_usage_count` are REMAINING counts! -/
def projectMinimaxUsage (body : JVal) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let baseResp := body.fieldOrNull "base_resp"
  let statusCode := (baseResp.fieldInt? "status_code").getD 0
  if statusCode == 2062 then
    return (#[("usage_note", .str "No active Token Plan subscription for this API key.")], #[], .null)
  if statusCode != 0 then
    return (#[("usage_note", .str "Token Plan usage unavailable for this API key.")], #[], .null)

  let remains := (body.fieldArr? "model_remains").getD #[]
  if remains.isEmpty then
    return (#[("usage_note", .str "No active Token Plan subscription for this API key.")], #[], .null)

  let mut modelUsage : Array JVal := #[]
  let mut primaryEntry? : Option JVal := none
  for item in remains do
    let mName := (item.fieldStr? "model_name").getD "unknown"
    if primaryEntry?.isNone || mName == "general" then
      primaryEntry? := some item
    let intRemPct : Nat :=
      if let some p := item.fieldNat? "current_interval_remaining_percent" then min p 100
      else
        let tot := (item.fieldNat? "current_interval_total_count").getD 0
        let remCnt := (item.fieldNat? "current_interval_usage_count").getD 0
        if tot > 0 then min ((remCnt * 100 + tot / 2) / tot) 100 else 100
    let wkRemPct : Nat :=
      if let some p := item.fieldNat? "current_weekly_remaining_percent" then min p 100
      else
        let tot := (item.fieldNat? "current_weekly_total_count").getD 0
        let remCnt := (item.fieldNat? "current_weekly_usage_count").getD 0
        if tot > 0 then min ((remCnt * 100 + tot / 2) / tot) 100 else 100
    let intResetSec : UInt64 := ((item.field? "end_time").bind jvalEpochSec?).getD 0
    let wkResetSec : UInt64 := ((item.field? "weekly_end_time").bind jvalEpochSec?).getD 0
    modelUsage := modelUsage.push (.obj #[
      ("model", .str mName),
      ("interval_remaining_percent", JVal.nat intRemPct),
      ("weekly_remaining_percent", JVal.nat wkRemPct),
      ("interval_reset", JVal.uint64 intResetSec),
      ("weekly_reset", JVal.uint64 wkResetSec)
    ])

  let mut fields : Array (String × JVal) := #[]
  let mut optWins : Array JVal := #[]
  let primary? :=
    (modelUsage.find? (fun m => (m.fieldStr? "model").getD "" == "general")).orElse (fun _ => modelUsage[0]?)
  if let some first := primary? then
    let intRem := (first.fieldNat? "interval_remaining_percent").getD 100
    let wkRem := (first.fieldNat? "weekly_remaining_percent").getD 100
    let intRst := (first.fieldUInt64? "interval_reset").getD 0
    let wkRst := (first.fieldUInt64? "weekly_reset").getD 0
    fields := fields.push ("minimax_interval_remaining_percent", JVal.nat intRem)
    if intRst > 0 then fields := fields.push ("minimax_interval_reset", JVal.uint64 intRst)
    fields := fields.push ("minimax_weekly_remaining_percent", JVal.nat wkRem)
    if wkRst > 0 then fields := fields.push ("minimax_weekly_reset", JVal.uint64 wkRst)
    fields := fields.push ("model_usage", .arr modelUsage)
    let used5h := toString (100 - min intRem 100)
    let usedWk := toString (100 - min wkRem 100)
    optWins := optWins.push (buildOptimizeWindow "minimax_5h" "5-hour" "prompts" "minimax_coding_plan" used5h 18000 (if intRst > 0 then some (formatEpochIso8601Utc intRst) else none))
    optWins := optWins.push (buildOptimizeWindow "minimax_weekly" "weekly" "prompts" "minimax_coding_plan" usedWk 604800 (if wkRst > 0 then some (formatEpochIso8601Utc wkRst) else none))

  return (fields, optWins, selectPrimaryOptimizeWindow optWins)

/-- Pure Z.ai quota monitor projector (`GET https://api.z.ai/api/monitor/usage/quota/limit`). -/
def projectZaiUsage (body : JVal) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[]
  let mut optWins : Array JVal := #[]
  let dObj := (body.field? "data").getD body
  if let some lvl := (dObj.fieldStr? "level").map (·.trimAscii.toString) then
    if !lvl.isEmpty then
      fields := fields.push ("zai_plan", .str lvl)
  let mut has5h := false
  let mut hasWeekly := false
  for lim in (dObj.fieldArr? "limits").getD #[] do
    let lType := (lim.fieldStr? "type").getD ""
    let pct? := (lim.field? "percentage").bind jvalNumRaw?
    let resetSec? := (lim.field? "nextResetTime").bind jvalEpochSec?
    let unit := (lim.fieldNat? "unit").getD 0
    let num := (lim.fieldNat? "number").getD 0
    if lType == "TOKENS_LIMIT" || lType.isEmpty then
      if let some pct := pct? then
        if (unit == 3 && num == 5) || (unit == 0 && num == 0 && !has5h) then
          has5h := true
          fields := fields.push ("zai_5h_used_percent", .num pct)
          if let some r := resetSec? then fields := fields.push ("zai_5h_reset", JVal.uint64 r)
          optWins := optWins.push (buildOptimizeWindow "zai_5h" "5-hour" "tokens" "zai_quota_limit" pct 18000 (resetSec?.map formatEpochIso8601Utc))
        else if unit == 6 && num == 1 then
          hasWeekly := true
          fields := fields.push ("zai_weekly_used_percent", .num pct)
          if let some r := resetSec? then fields := fields.push ("zai_weekly_reset", JVal.uint64 r)
          optWins := optWins.push (buildOptimizeWindow "zai_weekly" "weekly" "tokens" "zai_quota_limit" pct 604800 (resetSec?.map formatEpochIso8601Utc))
        else if !has5h && !hasWeekly then
          fields := fields.push ("zai_tokens_percentage", .num pct)
          if let some r := resetSec? then fields := fields.push ("zai_tokens_reset", JVal.uint64 r)
          optWins := optWins.push (buildOptimizeWindow "zai_tokens" "tokens" "tokens" "zai_quota_limit" pct 18000 (resetSec?.map formatEpochIso8601Utc))
    else if lType == "TIME_LIMIT" then
      if let some pct := pct? then
        fields := fields.push ("zai_mcp_percentage", .num pct)
        if let some r := resetSec? then fields := fields.push ("zai_mcp_reset", JVal.uint64 r)
  return (fields, optWins, selectPrimaryOptimizeWindow optWins)

/-- Pure Antigravity `loadCodeAssist` plan & verification projector.
    Never fabricates `"Pro"` when `paidTier.name` and `currentTier.name` are absent. -/
def projectAntigravityAssist (aJv : JVal) : Option String × Bool := Id.run do
  let tierName (k : String) : Option String :=
    ((aJv.field? k).bind (·.fieldStr? "name")).map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let plan? := tierName "paidTier" <|> tierName "currentTier"
  let projStr :=
    ((aJv.fieldStr? "cloudaicompanionProject").orElse fun _ =>
      (aJv.field? "cloudaicompanionProject").bind (·.fieldStr? "id")).getD ""
  let hasProject := !projStr.trimAscii.isEmpty
  let ineligible := ((aJv.fieldArr? "ineligibleTiers").getD #[]).size > 0
  let hasTierObj :=
    (match aJv.field? "currentTier" with | some (.obj _) => true | _ => false) ||
    (match aJv.field? "paidTier" with | some (.obj _) => true | _ => false)
  let needsVerification := !hasProject && ineligible && !hasTierObj
  return (plan?, needsVerification)

/-- Parsed CLIProxyAPI `/v0/management/auth-files` entry used internally to join sidecar
    parked credentials onto Core provider rows without exposing `name` or `email` on any
    API response. -/
private structure SidecarAuthFileEntry where
  name : String
  provider : String
  email : String := ""
  disabled : Bool := false
  needsReauth : Bool := false
  loginReason : UInt8 := 0
  remainingSecs : UInt64 := 0
  retryAt? : Option String := none
  reason? : Option String := none
  /-- Google refused this login until its owner verifies the account (a proxied Cloud Code
      403 `VALIDATION_REQUIRED` recorded by the sidecar). -/
  needsVerification : Bool := false
  /-- Google's `https://` verification link for that refusal, when it sent one. -/
  verificationUrl? : Option String := none
  deriving Inhabited

/-- Read a Cloud Code verification refusal from a sidecar auth-file `status_message` (the
    refusal as a JSON object, or the JSON string CLIProxyAPI stores). `some url?` only for a
    403 whose details carry reason `VALIDATION_REQUIRED` in domain `cloudcode-pa.googleapis.com`;
    the message text is never matched. The link is kept only when it is a plain `https://` URL. -/
def antigravityValidationRequired? (statusMessage : JVal) : Option (Option String) := do
  let body ← match statusMessage with
    | .str raw => (OrbBin.Json.parse raw).toOption
    | .obj _ => some statusMessage
    | _ => none
  let err ← body.field? "error"
  if err.fieldNat? "code" != some 403 then none
  let detail ← ((err.fieldArr? "details").getD #[]).find? fun d =>
    d.fieldStr? "reason" == some "VALIDATION_REQUIRED" &&
    d.fieldStr? "domain" == some "cloudcode-pa.googleapis.com"
  let url? := ((detail.field? "metadata").bind (·.fieldStr? "validation_url")).filter fun u =>
    u.startsWith "https://" && u.length ≤ 2048 && u.all (fun ch => ch.val > 32 && ch.val < 127)
  return url?

private def validSidecarReasonSlug (s : String) : Bool :=
  1 ≤ s.length && s.length ≤ 40 &&
  s.all (fun c => ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_')

private def validSidecarRetryAt (s : String) : Bool :=
  1 ≤ s.length && s.length ≤ 35 &&
  s.all (fun c => ('0' ≤ c && c ≤ '9') || c == '-' || c == ':' || c == 'T' || c == 'Z' || c == '+' || c == '.')

/-- Read CLIProxyAPI `/v0/management/auth-files` with a strict 2-second timeout.
    Any transport error, missing management key, or malformed payload degrades to `#[]`. -/
private def fetchSidecarAuthFiles (http : UsageHttp := liveUsageHttp) : IO (Array SidecarAuthFileEntry) := do
  let mgmtBase ← resolveCliProxyBaseUrl
  let some mgmtKey ← resolveCliProxyMgmtKey?
    | return #[]
  match ← http "GET" s!"{mgmtBase}/v0/management/auth-files" (some mgmtKey) none #[] 2000 262144 with
  | .ok (200, _, some jv) =>
    let files := (jv.fieldArr? "files").getD #[]
    let mut out : Array SidecarAuthFileEntry := #[]
    for f in files do
      let name := (f.fieldStr? "name").getD ""
      let prov := ((f.fieldStr? "provider").orElse (fun _ => f.fieldStr? "type")).getD "" |>.trimAscii.toString.toLower
      if !name.isEmpty && !prov.isEmpty then
        let email := ((f.fieldStr? "email").getD "").trimAscii.toString
        let disabled := (f.fieldBool? "disabled").getD false
        let status := (f.fieldStr? "status").getD ""
        let message := (f.fieldStr? "status_message").getD ""
        let refreshFailed := isAuthRejection 0 status message
        let validation? := if prov == "antigravity" then (f.field? "status_message").bind antigravityValidationRequired? else none
        let cds := (f.fieldArr? "cooldowns").getD #[]
        let mut bestRem : UInt64 := 0
        let mut bestRetry? : Option String := none
        let mut bestReason? : Option String := none
        for cd in cds do
          let rem := (cd.fieldUInt64? "remaining_seconds").getD 0
          if rem > bestRem then
            bestRem := rem
            bestRetry? := (cd.fieldStr? "retry_at").filter validSidecarRetryAt
            bestReason? := (cd.fieldStr? "reason").filter validSidecarReasonSlug
        let loginReason := Orb.Kernel.providerLoginReason refreshFailed disabled
          (status == "expired" || (message.splitOn "token_expired").length > 1)
          (bestRem > 0 && (bestReason? == some "quota_exhausted" ||
            bestReason? == some "credential_quota" || bestReason? == some "quota"))
        out := out.push {
          name := name
          provider := prov
          email := email
          disabled := disabled
          needsReauth := !disabled && loginReason != 0
          loginReason := loginReason
          remainingSecs := bestRem
          retryAt? := bestRetry?
          reason? := bestReason?
          needsVerification := validation?.isSome
          verificationUrl? := validation?.join
        }
    return out
  | _ => return #[]

/-- Outcome of one Antigravity Cloud Code call. -/
private inductive AntigravityCall where
  | ok (body : JVal)
  /-- The access token Core read was refused. CLIProxyAPI owns its renewal. -/
  | unauthorized
  | unavailable (reason : String)

private def antigravityCall (http : UsageHttp) (token method : String) (body : JVal) (maxBytes : Nat) : IO AntigravityCall := do
  match ← http "POST" s!"https://cloudcode-pa.googleapis.com/v1internal:{method}" (some token) (some body)
      #[("User-Agent", "antigravity")] 10000 maxBytes with
  | .ok (code, _, body?) =>
    if 200 ≤ code && code < 300 then
      match body? with
      | some jv => return .ok jv
      | none => return .unavailable "Unreadable Antigravity quota"
    else if code == 401 || code == 403 then return .unauthorized
    else return .unavailable s!"Antigravity quota returned HTTP {code}"
  | .error _ => return .unavailable "Antigravity quota unreachable"

/-- Read one provider account's usage from its vendor. `http` is the only way out to the vendor
    for the Kimi, Muse Code and Antigravity adapters (and the sidecar row Antigravity joins). -/
def fetchLiveProviderUsage (hp : HydratedProvider) (managementHttp : UsageHttp := liveUsageHttp)
    (resolveTransport? : Option ResolveTransport := none) : IO JVal := do
  let http : UsageHttp := match resolveTransport? with
    | none => managementHttp
    | some resolve => fun method url bearer body headers timeoutMs maxBytes =>
      sendJsonRequest method url bearer body headers timeoutMs maxBytes (some resolve)
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let pType := hp.providerType.toLower
  let hasCreds := hp.hasApiKey || hp.hasOAuth
  let emailJv : JVal := if hp.accountEmail.isEmpty then .null else .str hp.accountEmail

  if !hasCreds then
    return .obj #[
      ("provider_type", .str hp.providerType),
      ("provider_name", .str hp.name),
      ("account_email", emailJv),
      ("status", .str "no_credentials"),
      ("optimize", .obj #[("as_of", .str nowIso), ("primary_window", .null), ("windows", .arr #[])])
    ]

  let mut extraFields : Array (String × JVal) := #[]
  let mut optWindows : Array JVal := #[]
  let mut primaryWin : JVal := .null
  let mut statusStr := "connected"

  -- 1. OpenAI Codex OAuth (`wham/usage`) or OpenAI API Key rate-limit probe
  if pType == "openai" then
    if hp.hasOAuth && !hp.oauthToken.isEmpty then
      if let .ok (code, _, some wham) ← http "GET" "https://chatgpt.com/backend-api/wham/usage" (some hp.oauthToken) none #[] 6000 262144 then
        if 200 ≤ code && code < 300 then
          let (fields, windows, primary) := projectCodexUsage wham
          extraFields := fields
          optWindows := windows
          primaryWin := primary
        else if code == 401 || code == 403 then
          statusStr := "needs_reauth"
    else if !hp.apiKey.isEmpty then
      let hdrs := #[("Authorization", s!"Bearer {hp.apiKey}"), ("Content-Type", "application/json")]
      let probeBody := (renderCompact (.obj #[
        ("model", .str "gpt-4.1-nano"),
        ("max_tokens", JVal.nat 1),
        ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "hi")]])
      ])).toUTF8
      if let .ok resp ← sendRequest (resolveTransport? := resolveTransport?) "POST" "https://api.openai.com/v1/chat/completions" hdrs probeBody 6000 65536 then
        extraFields := extraFields.push ("status_code", JVal.nat resp.status)
        if resp.status == 401 || resp.status == 403 then
          statusStr := "needs_reauth"
        if let some org := findHeaderCI? resp.headers "openai-organization" then
          extraFields := extraFields.push ("organization", .str org.trimAscii.toString)
        for (hName, fName) in #[
          ("x-ratelimit-limit-requests", "requests_limit"),
          ("x-ratelimit-remaining-requests", "requests_remaining"),
          ("x-ratelimit-reset-requests", "requests_reset"),
          ("x-ratelimit-limit-tokens", "tokens_limit"),
          ("x-ratelimit-remaining-tokens", "tokens_remaining"),
          ("x-ratelimit-reset-tokens", "tokens_reset")
        ] do
          if let some v := findHeaderCI? resp.headers hName then
            extraFields := extraFields.push (fName, .str v.trimAscii.toString)

  -- 2. Anthropic OAuth or API Key
  else if pType == "anthropic" then
    let tok := if !hp.oauthToken.isEmpty then hp.oauthToken else hp.apiKey
    if !tok.isEmpty then
      let hdrs :=
        if !hp.oauthToken.isEmpty then
          #[("Authorization", s!"Bearer {tok}"), ("anthropic-beta", "oauth-2025-04-20"), ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")]
        else
          #[("x-api-key", tok), ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")]
      let probeObj : Array (String × JVal) :=
        (if !hp.oauthToken.isEmpty then #[("system", .str "You are Claude Code, Anthropic's official CLI for Claude.")] else #[]) ++
        #[
          ("model", .str "claude-haiku-4-5-20251001"),
          ("max_tokens", JVal.nat 1),
          ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "hi")]])
        ]
      let probeBody := (renderCompact (.obj probeObj)).toUTF8
      if let .ok resp ← sendRequest (resolveTransport? := resolveTransport?) "POST" "https://api.anthropic.com/v1/messages" hdrs probeBody 6000 65536 then
        extraFields := extraFields.push ("status_code", JVal.nat resp.status)
        if resp.status == 401 || resp.status == 403 then
          statusStr := "needs_reauth"
        if let some orgId := findHeaderCI? resp.headers "anthropic-organization-id" then
          extraFields := extraFields.push ("organization_id", .str orgId.trimAscii.toString)
        for (hName, fName) in #[
          ("anthropic-ratelimit-unified-status", "unified_status"),
          ("anthropic-ratelimit-unified-reset", "unified_reset"),
          ("anthropic-ratelimit-unified-5h-status", "unified_5h_status"),
          ("anthropic-ratelimit-unified-7d-status", "unified_7d_status"),
          ("anthropic-ratelimit-unified-representative-claim", "unified_representative_claim"),
          ("anthropic-ratelimit-unified-fallback-percentage", "unified_fallback_pct"),
          ("anthropic-ratelimit-unified-overage-status", "unified_overage_status"),
          ("anthropic-ratelimit-unified-overage-disabled-reason", "unified_overage_disabled_reason"),
          ("anthropic-ratelimit-requests-limit", "requests_limit"),
          ("anthropic-ratelimit-requests-remaining", "requests_remaining"),
          ("anthropic-ratelimit-requests-reset", "requests_reset"),
          ("anthropic-ratelimit-tokens-limit", "tokens_limit"),
          ("anthropic-ratelimit-tokens-remaining", "tokens_remaining"),
          ("anthropic-ratelimit-tokens-reset", "tokens_reset"),
          ("anthropic-ratelimit-input-tokens-limit", "input_tokens_limit"),
          ("anthropic-ratelimit-input-tokens-remaining", "input_tokens_remaining"),
          ("anthropic-ratelimit-output-tokens-limit", "output_tokens_limit"),
          ("anthropic-ratelimit-output-tokens-remaining", "output_tokens_remaining")
        ] do
          if let some v := findHeaderCI? resp.headers hName then
            extraFields := extraFields.push (fName, .str v.trimAscii.toString)
        if let some u5 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-5h-utilization" then
          let pct5 := match u5.trimAscii.toString.toNat? with | some n => toString n | none => u5.trimAscii.toString
          let r5 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-5h-reset"
          extraFields := extraFields.push ("unified_5h_utilization", .num u5.trimAscii.toString)
          if let some rv := r5 then extraFields := extraFields.push ("unified_5h_reset", .str rv)
          optWindows := optWindows.push (buildOptimizeWindow "5h" "5-hour" "utilization_pct" "anthropic_unified_headers" pct5 18000 r5)
        if let some u7 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-7d-utilization" then
          let pct7 := match u7.trimAscii.toString.toNat? with | some n => toString n | none => u7.trimAscii.toString
          let r7 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-7d-reset"
          extraFields := extraFields.push ("unified_7d_utilization", .num u7.trimAscii.toString)
          if let some rv := r7 then extraFields := extraFields.push ("unified_7d_reset", .str rv)
          optWindows := optWindows.push (buildOptimizeWindow "7d" "7-day" "utilization_pct" "anthropic_unified_headers" pct7 604800 r7)
        primaryWin := selectPrimaryOptimizeWindow optWindows
      -- Model-specific weekly limits (Opus, Sonnet, Fable, ...) are metered apart from the
      -- overall weekly limit and only reported by the OAuth usage endpoint.
      if !hp.oauthToken.isEmpty then
        if let .ok (code, _, some uJv) ← http "GET" "https://api.anthropic.com/api/oauth/usage"
            (some hp.oauthToken) none #[("anthropic-beta", "oauth-2025-04-20")] 6000 65536 then
          if 200 ≤ code && code < 300 then
            let wins := anthropicModelWindows uJv
            if !wins.isEmpty then extraFields := extraFields.push ("anthropic_model_windows", .arr wins)

  -- 3. Kimi Coding Usage + Moonshot Cash Balance
  else if pType == "kimi" then
    let tok := if !hp.oauthToken.isEmpty then hp.oauthToken else hp.apiKey
    if !tok.isEmpty then
      match ← http "GET" "https://api.kimi.com/coding/v1/usages" (some tok) none #[("User-Agent", "KimiCLI/1.5")] 5000 262144 with
      | .ok (code, _, body?) =>
        if 200 ≤ code && code < 300 then
          if let some kJv := body? then
            let (fields, windows, primary) := projectKimiUsage kJv nowSec
            extraFields := extraFields ++ fields
            optWindows := windows
            primaryWin := primary
        else if code == 401 || code == 403 then
          statusStr := "needs_reauth"
          extraFields := extraFields.push ("error", .str s!"Kimi Code usage endpoint returned HTTP {code}")
      | .error _ =>
        extraFields := extraFields.push ("error", .str "Failed to reach Kimi usage API")
    if !hp.apiKey.isEmpty then
      if let .ok (bCode, _, some bJv) ← http "GET" "https://api.moonshot.ai/v1/users/me/balance" (some hp.apiKey) none #[] 5000 65536 then
        if 200 ≤ bCode && bCode < 300 then
          let dObj := (bJv.field? "data").getD bJv
          if let some avail := (dObj.field? "available_balance").bind jvalNumRaw? then
            extraFields := extraFields.push ("kimi_available_balance", .num avail)
          if let some cash := (dObj.field? "cash_balance").bind jvalNumRaw? then
            extraFields := extraFields.push ("kimi_cash_balance", .num cash)
          if let some voucher := (dObj.field? "voucher_balance").bind jvalNumRaw? then
            extraFields := extraFields.push ("kimi_voucher_balance", .num voucher)

  -- 4. Z.ai Quota Monitor
  else if pType == "zai" && !hp.apiKey.isEmpty then
    if let .ok (code, _, body?) ← http "GET" "https://api.z.ai/api/monitor/usage/quota/limit" none none #[("Authorization", hp.apiKey)] 5000 262144 then
      if 200 ≤ code && code < 300 then
        if let some zJv := body? then
          let (fields, windows, primary) := projectZaiUsage zJv
          extraFields := fields
          optWindows := windows
          primaryWin := primary
      else if code == 401 || code == 403 then
        statusStr := "needs_reauth"

  -- 5. Muse Code subscription quota & Muse pay-as-you-go note
  else if pType == "muse-code" then
    -- The quota read takes the device credential. The minted key and the Meta API key are a
    -- different role: they are never sent here, and there is no fallback to them.
    if hp.deviceToken.isEmpty then
      extraFields := extraFields.push ("usage_note", .str "Muse Code subscription via CLIProxyAPI. No fallback to the Meta API account.")
    else
      let unavailable (reason : String) : String × JVal :=
        ("usage_note", .str s!"Muse Code quota is unavailable right now ({reason}).")
      match ← http "POST" "https://api.meta.ai/muse-code/key" (some hp.deviceToken) (some (.obj #[])) #[] 5000 262144 with
      | .ok (code, _, body?) =>
        if 200 ≤ code && code < 300 then
          match body? with
          | some mJv =>
            let (fields, windows, primary) := projectMuseCodeUsage mJv
            extraFields := fields
            optWindows := windows
            primaryWin := primary
          | none => extraFields := extraFields.push (unavailable "Unreadable Muse Code quota")
        else if code == 401 || code == 403 then
          statusStr := "needs_reauth"
          extraFields := extraFields.push ("error", .str "Muse Code rejected the saved login")
        else
          extraFields := extraFields.push (unavailable s!"Muse Code quota returned HTTP {code}")
      | .error _ =>
        extraFields := extraFields.push (unavailable "Muse Code quota unreachable")

  else if pType == "muse" then
    extraFields := extraFields.push ("usage_note", .str "This API key uses pay-as-you-go billing. Muse Code subscription quota requires a separate Muse Code account connection.")

  -- 6. xAI / Grok OAuth CLI billing & API key introspection
  else if pType == "xai" then
    if !hp.oauthToken.isEmpty then
      let xHdrs := #[("x-xai-token-auth", "xai-grok-cli"), ("User-Agent", "grok-cli/0.1.0")]
      let mut settingsJv? : Option JVal := none
      if let .ok (sCode, _, some sJv) ← http "GET" "https://cli-chat-proxy.grok.com/v1/settings" (some hp.oauthToken) none xHdrs 5000 65536 then
        if 200 ≤ sCode && sCode < 300 then settingsJv? := some sJv
        else if sCode == 401 || sCode == 403 then statusStr := "needs_reauth"
      if let .ok (bCode, _, body?) ← http "GET" "https://cli-chat-proxy.grok.com/v1/billing?format=credits" (some hp.oauthToken) none xHdrs 5000 262144 then
        if 200 ≤ bCode && bCode < 300 then
          if let some bJv := body? then
            let (fields, windows, primary) := projectXaiBillingUsage bJv settingsJv?
            extraFields := extraFields ++ fields
            optWindows := windows
            primaryWin := primary
        else if bCode == 401 || bCode == 403 then
          statusStr := "needs_reauth"
    if !hp.apiKey.isEmpty then
      if let .ok (kCode, _, body?) ← http "GET" "https://api.x.ai/v1/api-key" (some hp.apiKey) none #[] 5000 65536 then
        extraFields := extraFields.push ("status_code", JVal.nat kCode)
        if 200 ≤ kCode && kCode < 300 then
          if let some kJv := body? then
            if let some kn := (kJv.fieldStr? "name").orElse (fun _ => kJv.fieldStr? "apiKeyName") then
              if !kn.trimAscii.isEmpty then extraFields := extraFields.push ("xai_key_name", .str kn.trimAscii.toString)
            if let some tid := (kJv.fieldStr? "teamId").orElse (fun _ => (kJv.fieldStr? "team_id").orElse (fun _ => kJv.fieldStr? "teamID")) then
              if !tid.trimAscii.isEmpty then extraFields := extraFields.push ("xai_team_id", .str tid.trimAscii.toString)
            if let some rem := (kJv.field? "remainingCredits").bind jvalNumRaw? then
              extraFields := extraFields.push ("xai_prepaid_usd", .num rem)
        else if kCode == 401 || kCode == 403 then
          statusStr := "needs_reauth"

  -- 7. MiniMax Coding Plan / Token Plan remains
  else if pType == "minimax" then
    let tok := if !hp.apiKey.isEmpty then hp.apiKey else hp.oauthToken
    if !tok.isEmpty then
      if let .ok (code, _, body?) ← http "GET" "https://www.minimax.io/v1/api/openplatform/coding_plan/remains" (some tok) none #[] 6000 262144 then
        if 200 ≤ code && code < 300 then
          if let some mJv := body? then
            let (fields, windows, primary) := projectMinimaxUsage mJv
            extraFields := fields
            optWindows := windows
            primaryWin := primary
        else if code == 401 || code == 403 then
          statusStr := "needs_reauth"

  -- 8. Cerebras rate-limit headers probe
  else if pType == "cerebras" && !hp.apiKey.isEmpty then
    let hdrs := #[("Authorization", s!"Bearer {hp.apiKey}"), ("Content-Type", "application/json")]
    let probeBody := (renderCompact (.obj #[
      ("model", .str "llama3.1-8b"),
      ("max_tokens", JVal.nat 1),
      ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "hi")]])
    ])).toUTF8
    if let .ok resp ← sendRequest (resolveTransport? := resolveTransport?) "POST" "https://api.cerebras.ai/v1/chat/completions" hdrs probeBody 6000 65536 then
      extraFields := extraFields.push ("status_code", JVal.nat resp.status)
      if resp.status == 401 || resp.status == 403 then
        statusStr := "needs_reauth"
      for (hName, fName) in #[
        ("x-ratelimit-limit-requests-day", "requests_limit_day"),
        ("x-ratelimit-remaining-requests-day", "requests_remaining_day"),
        ("x-ratelimit-reset-requests-day", "requests_reset_day"),
        ("x-ratelimit-limit-tokens-minute", "tokens_limit_minute"),
        ("x-ratelimit-remaining-tokens-minute", "tokens_remaining_minute"),
        ("x-ratelimit-reset-tokens-minute", "tokens_reset_minute")
      ] do
        if let some v := findHeaderCI? resp.headers hName then
          extraFields := extraFields.push (fName, .str v.trimAscii.toString)

  -- 9. Antigravity Cloud Code: eligibility and plan from `loadCodeAssist`, then the shared
  -- 5h/weekly windows from `retrieveUserQuotaSummary`, falling back to per-model
  -- `retrieveUserQuota`. A refused access token is not a lost login: CLIProxyAPI renews it.
  else if pType == "antigravity" && !hp.oauthToken.isEmpty then
    let refreshNote : String × JVal :=
      ("usage_note", .str "Antigravity quota is unavailable until the Google login refreshes.")
    let unavailable (reason : String) : String × JVal :=
      ("usage_note", .str s!"Antigravity quota is unavailable right now ({reason}).")
    let verifyNote : String × JVal :=
      ("usage_note", .str "Google Cloud Code requires account verification before Antigravity quota can be used.")
    let assistBody : JVal := .obj #[("metadata", .obj #[
      ("ideType", .str "ANTIGRAVITY"), ("platform", .str "PLATFORM_UNSPECIFIED"), ("pluginType", .str "GEMINI")])]
    let mut verifyNoted := false
    match ← antigravityCall http hp.oauthToken "loadCodeAssist" assistBody 262144 with
    | .unauthorized => extraFields := extraFields.push refreshNote
    | .unavailable reason => extraFields := extraFields.push (unavailable reason)
    | .ok aJv =>
      let (plan?, needsVerif) := projectAntigravityAssist aJv
      if needsVerif then
        -- Google serves nothing until the owner verifies the account: no plan, no quota read.
        statusStr := "needs_verification"
        extraFields := extraFields.push ("antigravity_eligibility", .str "needs_verification")
        for tier in (aJv.fieldArr? "ineligibleTiers").getD #[] do
          if tier.fieldStr? "reasonCode" == some "VALIDATION_REQUIRED" then
            if let some url := (tier.fieldStr? "validationUrl").filter (·.startsWith "https://") then
              extraFields := extraFields.push ("verification_url", .str url)
              break
        extraFields := extraFields.push verifyNote
        verifyNoted := true
      else
        if let some plan := plan? then
          extraFields := extraFields.push ("antigravity_plan", .str plan)
        let projStr :=
          ((aJv.fieldStr? "cloudaicompanionProject").orElse fun _ =>
            (aJv.field? "cloudaicompanionProject").bind (·.fieldStr? "id")).getD ""
        let quotaBody : JVal := if projStr.trimAscii.isEmpty then .obj #[] else .obj #[("project", .str projStr.trimAscii.toString)]
        let mut windows? : Option (Array JVal) := none
        let mut unauthorized := false
        let mut failure? : Option String := none
        match ← antigravityCall http hp.oauthToken "retrieveUserQuotaSummary" quotaBody 1048576 with
        | .ok sJv =>
          let summary := parseAntigravitySummary sJv
          if !summary.isEmpty then
            -- The summary drops the Gemini group once it is exhausted; read it per model.
            let hasGemini := summary.any fun w => ((w.fieldStr? "label").getD "").startsWith "Gemini"
            let mut merged := summary
            if !hasGemini then
              if let .ok qJv ← antigravityCall http hp.oauthToken "retrieveUserQuota" quotaBody 1048576 then
                if let some g := antigravityGeminiWindow? qJv (← nowEpoch) then merged := #[g] ++ merged
            windows? := some merged
        | .unauthorized => unauthorized := true
        | .unavailable reason => failure? := some reason
        if windows?.isNone && !unauthorized then
          match ← antigravityCall http hp.oauthToken "retrieveUserQuota" quotaBody 1048576 with
          | .ok qJv => windows? := some (parseAntigravityQuota qJv)
          | .unauthorized => unauthorized := true
          | .unavailable reason => failure? := some reason
        if unauthorized then extraFields := extraFields.push refreshNote
        else
          match windows? with
          | some windows => extraFields := extraFields.push ("antigravity_windows", .arr windows)
          -- Neither quota view answered: say so instead of reporting an empty quota.
          | none => extraFields := extraFields.push (unavailable (failure?.getD "Antigravity quota unreachable"))
    -- Google can accept the login and still refuse every request until its owner verifies the
    -- account. That refusal, and its link, exist only on the sidecar's row for this auth file.
    if !hp.oauthFile.isEmpty then
      let sidecarFiles ← fetchSidecarAuthFiles managementHttp
      if let some row := sidecarFiles.find? (fun f => f.name == hp.oauthFile && f.needsVerification) then
        statusStr := "needs_verification"
        if !verifyNoted then
          extraFields := (extraFields.filter (·.1 != "usage_note")).push verifyNote
        if let some url := row.verificationUrl? then
          extraFields := (extraFields.filter (·.1 != "verification_url")).push ("verification_url", .str url)

  let baseFields : Array (String × JVal) := #[
    ("provider_type", .str hp.providerType),
    ("provider_name", .str hp.name),
    ("account_email", emailJv),
    ("status", .str statusStr)
  ] ++ extraFields ++ #[
    ("optimize", .obj #[
      ("as_of", .str nowIso),
      ("primary_window", primaryWin),
      ("windows", .arr optWindows)
    ])
  ]
  return .obj baseFields

private def probeProviderUsage (hub : ProviderRuntimeHub) (hp : HydratedProvider) : IO JVal :=
  match hub.usageProbe? with
  | some probe => probe hp.id
  | none => fetchLiveProviderUsage hp hub.usageHttp (hub.resolveTransport?.map (fun resolve => resolve hp.providerType hp.id))

/-- Seconds after which a cached usage entry is refreshed again. -/
def usageRefreshAfterSecs : UInt64 := 120

/-- The Codex OAuth usage read is never polled on a timer: only an explicit request reads it. -/
private def usageProbeOnDemandOnly (hp : HydratedProvider) : Bool :=
  hp.providerType.toLower == "openai" && !hp.hasApiKey && hp.hasOAuth

/-- Claim the refresh of one provider's cached usage. `none` when a refresh already holds it;
    otherwise the cache generation the result must still match to be stored. -/
private def claimUsageRefresh (hub : ProviderRuntimeHub) (hp : HydratedProvider) : IO (Option Nat) :=
  hub.mu.atomically do
    let st ← get
    if st.refreshingProviderIds.contains hp.id then
      return none
    match st.usageEntries.find? (fun e => e.providerId == hp.id) with
    | some existing =>
      if existing.refreshing then return none
      let updated := st.usageEntries.map (fun e => if e.providerId == hp.id then { e with refreshing := true } else e)
      set { st with usageEntries := updated, refreshingProviderIds := st.refreshingProviderIds.push hp.id }
      return some st.usageGeneration
    | none =>
      set { st with refreshingProviderIds := st.refreshingProviderIds.push hp.id }
      return some st.usageGeneration

/-- Probe a claimed provider and store the result, unless the cache was reset meanwhile.
    Always releases the claim. -/
private def finishUsageRefresh (hub : ProviderRuntimeHub) (hp : HydratedProvider) (generation : Nat) : IO Unit := do
  let fresh ← (try probeProviderUsage hub hp catch _ =>
    pure (.obj #[("provider_type", .str hp.providerType), ("provider_name", .str hp.name), ("status", .str "error")]))
  let ts ← nowEpoch
  let tsIso := formatEpochIso8601Utc ts
  hub.mu.atomically do
    let st ← get
    let cleared := st.refreshingProviderIds.filter (· != hp.id)
    if st.usageGeneration == generation then
      let others := st.usageEntries.filter (fun e => e.providerId != hp.id)
      let entry : CachedUsageEntry := {
        providerId := hp.id
        fetchedSec := ts
        fetchedIso := tsIso
        payload := fresh
        refreshing := false
      }
      set { st with usageEntries := others.push entry, refreshingProviderIds := cleared }
    else
      set { st with refreshingProviderIds := cleared }

private def refreshProviderUsageAsync (hub : ProviderRuntimeHub) (hp : HydratedProvider) : IO Unit := do
  if let some generation ← claimUsageRefresh hub hp then
    let _ ← IO.asTask (prio := .dedicated) (finishUsageRefresh hub hp generation)

/-- One pass of the background usage upkeep: refresh enabled observation-only adapters
    with credentials whose entry is missing or older than `refreshAfterSecs`, one at a time,
    `spreadMs` apart. It runs with no client open, so a login the vendor rejects is reported as
    `needs_reauth` before anyone looks. It only reads usage: renewing a login stays with
    CLIProxyAPI. Returns the ids it refreshed. -/
def runProviderUsageUpkeepPass (hub : ProviderRuntimeHub) (store : CoreStore) (workingDir : String)
    (spreadMs : UInt32 := 2000) (refreshAfterSecs : UInt64 := usageRefreshAfterSecs) : IO (Array String) := do
  let hps ← loadHydratedProviders store workingDir
  let mut refreshed : Array String := #[]
  for hp in hps do
    -- Only observation-only adapters belong on a timer. Other adapters can mint a
    -- key or send billable inference even though their caller asks for usage.
    if hp.enabled && (hp.hasApiKey || hp.hasOAuth) &&
        #["antigravity", "kimi", "zai", "minimax", "xai"].contains hp.providerType.toLower then
      let nowSec ← nowEpoch
      let isFresh ← hub.mu.atomically do
        return (← get).usageEntries.any (fun e => e.providerId == hp.id && nowSec < e.fetchedSec + refreshAfterSecs)
      if !isFresh then
        if let some generation ← claimUsageRefresh hub hp then
          if !refreshed.isEmpty && spreadMs > 0 then IO.sleep spreadMs
          finishUsageRefresh hub hp generation
          refreshed := refreshed.push hp.id
  return refreshed

/-- The background usage upkeep duty of a serving Core: first pass after 20 s, then one every
    `usageRefreshAfterSecs`. An error in one pass never ends the duty. -/
def providerUsageUpkeepLoop (hub : ProviderRuntimeHub) (store : CoreStore) (workingDir : String) : IO Unit := do
  if ← isHermeticTestMode then return
  IO.sleep 20000
  while true do
    try discard <| runProviderUsageUpkeepPass hub store workingDir
    catch e => IO.eprintln s!"[sandboxed-sh] provider usage upkeep pass failed: {e}"
    IO.sleep (usageRefreshAfterSecs * 1000).toUInt32

private def decorateCachedUsage (entry : CachedUsageEntry) (nowSec : UInt64) : JVal :=
  let withCached := (entry.payload.setField "cached" (.bool true)).setField "fetched_at" (.str entry.fetchedIso)
  if nowSec >= entry.fetchedSec + 600 then
    withCached.setField "stale" (.bool true)
  else
    withCached

/-! ## Fast Indexed `GET /api/ai/usage/summary` over `proxy_usage` -/

private def parseWindowSeconds? (win : String) : Option UInt64 := Id.run do
  let w := win.trimAscii.toString.toLower
  if w.isEmpty || w == "all" then return none
  if w.endsWith "h" then
    return ((w.dropEnd 1).toString.toNat?).map (fun n => (n * 3600).toUInt64)
  if w.endsWith "d" then
    return ((w.dropEnd 1).toString.toNat?).map (fun n => (n * 86400).toUInt64)
  if w.endsWith "w" then
    return ((w.dropEnd 1).toString.toNat?).map (fun n => (n * 604800).toUInt64)
  return some 86400

private def sqlStringLiteral (s : String) : String :=
  "'" ++ s.replace "'" "''" ++ "'"

private def callerUsageScope (callerUserId : String) (effAdmin : Bool) : String :=
  if effAdmin || callerUserId.isEmpty then ""
  else s!" AND proxy_usage.mission_id IN (SELECT id FROM missions WHERE owner_user_id={sqlStringLiteral callerUserId})"

private def mkTotalsJv (ev inp outTok cRead cCreate reas costCents : Nat) : JVal :=
  let totalTok := inp + outTok + cRead + cCreate + reas
  let billableTok := inp + outTok + cCreate + reas
  .obj #[
    ("events", JVal.nat ev),
    ("requests", JVal.nat ev),
    ("input_tokens", JVal.nat inp),
    ("output_tokens", JVal.nat outTok),
    ("cache_read_tokens", JVal.nat cRead),
    ("cache_creation_tokens", JVal.nat cCreate),
    ("reasoning_tokens", JVal.nat reas),
    ("total_tokens", JVal.nat totalTok),
    ("billable_tokens", JVal.nat billableTok),
    ("recorded_cost_cents", JVal.nat costCents),
    ("estimated_cost_cents", JVal.nat costCents)
  ]

private def queryTotalsSince (store : CoreStore) (sinceIso? : Option String) (scopeSql : String := "") : IO JVal := do
  let (sql, args) :=
    match sinceIso? with
    | some s =>
      (s!"SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage WHERE timestamp >= ?1{scopeSql};", #[s])
    | none =>
      (s!"SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage WHERE 1=1{scopeSql};", #[])
  match ← execParamQuery store.missionsDb sql args with
  | .ok rs =>
    if rs.size > 1 then
      let r := rs[1]!
      let n (i : Nat) := ((r[i]?).bind String.toNat?).getD 0
      return mkTotalsJv (n 0) (n 1) (n 2) (n 3) (n 4) (n 5) (n 6)
    return mkTotalsJv 0 0 0 0 0 0 0
  | .error _ => return mkTotalsJv 0 0 0 0 0 0 0

private def queryGroupedUsageBuckets (store : CoreStore) (colExpr : String) (sinceIso? : Option String) (limit : Nat)
    (labelExpr? : Option String := none) (fromClause : String := "proxy_usage")
    (nullKeyVal : Option String := some "unknown") (nullLabelVal : Option String := none)
    (scopeSql : String := "") : IO (Array JVal) := do
  let (whereSql, args) :=
    match sinceIso? with
    | some s => (s!"WHERE proxy_usage.timestamp >= ?1{scopeSql}", #[s, toString limit])
    | none => (if scopeSql.isEmpty then "" else s!"WHERE 1=1{scopeSql}", #[toString limit])
  let limParam := if sinceIso?.isSome then "?2" else "?1"
  let lblCol := labelExpr?.getD colExpr
  let sql :=
    s!"SELECT {colExpr} AS k, {lblCol} AS lbl, COUNT(*), COALESCE(SUM(proxy_usage.input_tokens),0), COALESCE(SUM(proxy_usage.output_tokens),0), " ++
    s!"COALESCE(SUM(proxy_usage.cache_read_tokens),0), COALESCE(SUM(proxy_usage.cache_creation_tokens),0), COALESCE(SUM(proxy_usage.reasoning_tokens),0), COALESCE(SUM(proxy_usage.cost_cents),0) " ++
    s!"FROM {fromClause} {whereSql} GROUP BY k ORDER BY SUM(proxy_usage.input_tokens + proxy_usage.output_tokens) DESC LIMIT {limParam};"
  let mut out : Array JVal := #[]
  if let .ok rs ← execParamQuery store.missionsDb sql args then
    for i in [1:rs.size] do
      let r := rs[i]!
      let key := ((r[0]?).getD "").trimAscii.toString
      let lblRaw := ((r[1]?).getD "").trimAscii.toString
      let (keyJv, lblJv) : JVal × JVal :=
        if key.isEmpty then
          let kJv := match nullKeyVal with | some d => .str d | none => .null
          let lJv := match nullLabelVal.orElse (fun _ => nullKeyVal) with | some d => .str d | none => .null
          (kJv, lJv)
        else
          let effLbl := if lblRaw.isEmpty then key else lblRaw
          (.str key, .str effLbl)
      let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
      let totObj := mkTotalsJv (n 2) (n 3) (n 4) (n 5) (n 6) (n 7) (n 8)
      let totPairs := totObj.asObj?.getD #[]
      out := out.push (.obj (#[("key", keyJv), ("label", lblJv)] ++ totPairs))
  return out

/-- Walks `missions.parent_mission_id` to the root mission id, mirroring the bounded walk in
    `ResourcesAndSystem.resolveRootMission`: a depth cap of 8 plus a visited set means a parent
    cycle terminates, and a mission id with no `missions` row is its own root. -/
private def resolveRootMissionId (store : CoreStore) (mid : String) : IO String := do
  let mut cur := mid
  let mut visited : Array String := #[cur]
  for _hop in [0:8] do
    match ← execParamQuery store.missionsDb
        "SELECT COALESCE(parent_mission_id,'') FROM missions WHERE id=?1 LIMIT 1;" #[cur] with
    | .ok rs =>
      if rs.size ≤ 1 then return cur
      let parent := (rs[1]![0]?).getD ""
      if parent.isEmpty || parent == cur || visited.contains parent then return cur
      cur := parent
      visited := visited.push cur
    | .error _ => return cur
  return cur

/-- Rolls `by_mission` buckets up to their root mission (`missions.parent_mission_id`) and applies
    `limit` after the merge, so a parent never loses a child to a pre-merge top cut. -/
private def rollupByRootMission (store : CoreStore) (byMission : Array JVal) (limit : Nat) : IO (Array JVal) := do
  let mut roots : Array (String × Nat × Nat × Nat × Nat × Nat × Nat × Nat) := #[]
  let mut anyNull := false
  let mut nullAcc : Nat × Nat × Nat × Nat × Nat × Nat × Nat := (0, 0, 0, 0, 0, 0, 0)
  for b in byMission do
    let g (field : String) : Nat := (b.fieldNat? field).getD 0
    let ev := g "events"
    let inp := g "input_tokens"
    let outTok := g "output_tokens"
    let cRead := g "cache_read_tokens"
    let cCreate := g "cache_creation_tokens"
    let reas := g "reasoning_tokens"
    let costCents := g "recorded_cost_cents"
    match b.field? "key" with
    | some (.str key) =>
      let root ← resolveRootMissionId store key
      match roots.findIdx? (fun (k, _, _, _, _, _, _, _) => k == root) with
      | some idx =>
        let (k, e0, e1, e2, e3, e4, e5, e6) := roots[idx]!
        roots := roots.set! idx (k, e0 + ev, e1 + inp, e2 + outTok, e3 + cRead, e4 + cCreate, e5 + reas, e6 + costCents)
      | none =>
        roots := roots.push (root, ev, inp, outTok, cRead, cCreate, reas, costCents)
    | _ =>
      anyNull := true
      let (n0, n1, n2, n3, n4, n5, n6) := nullAcc
      nullAcc := (n0 + ev, n1 + inp, n2 + outTok, n3 + cRead, n4 + cCreate, n5 + reas, n6 + costCents)
  let mut out : Array (Nat × Option String × JVal) := #[]
  for (root, ev, inp, outTok, cRead, cCreate, reas, costCents) in roots do
    let totPairs := (mkTotalsJv ev inp outTok cRead cCreate reas costCents).asObj?.getD #[]
    out := out.push (inp + outTok, some root, .obj (#[("key", .str root), ("label", .str root)] ++ totPairs))
  if anyNull then
    let (ev, inp, outTok, cRead, cCreate, reas, costCents) := nullAcc
    let totPairs := (mkTotalsJv ev inp outTok cRead cCreate reas costCents).asObj?.getD #[]
    out := out.push (inp + outTok, none, .obj (#[("key", .null), ("label", .null)] ++ totPairs))
  let sorted := out.qsort fun (tA, kA, _) (tB, kB, _) =>
    if tA != tB then tA > tB
    else match kA, kB with
      | some a, some b => a < b
      | some _, none => true
      | none, _ => false
  return sorted.toList.take (Nat.min limit sorted.size) |>.toArray |>.map (fun (_, _, jv) => jv)

private def queryModelUsageBuckets (store : CoreStore) (sinceIso? : Option String) (limit : Nat)
    (scopeSql : String := "") : IO (Array JVal) := do
  let (whereSql, args) :=
    match sinceIso? with
    | some s => (s!"WHERE timestamp >= ?1{scopeSql}", #[s, toString limit])
    | none => (if scopeSql.isEmpty then "" else s!"WHERE 1=1{scopeSql}", #[toString limit])
  let limParam := if sinceIso?.isSome then "?2" else "?1"
  let sql :=
    "SELECT COALESCE(NULLIF(model,''),'unknown') AS m, COALESCE(MAX(NULLIF(provider,'')),'unknown') AS p, " ++
    "COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), " ++
    "COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) " ++
    s!"FROM proxy_usage {whereSql} GROUP BY m ORDER BY SUM(input_tokens + output_tokens) DESC LIMIT {limParam};"
  let mut out : Array JVal := #[]
  if let .ok rs ← execParamQuery store.missionsDb sql args then
    for i in [1:rs.size] do
      let r := rs[i]!
      let mdl := ((r[0]?).getD "unknown").trimAscii.toString
      let effMdl := if mdl.isEmpty then "unknown" else mdl
      let prov := ((r[1]?).getD "").trimAscii.toString
      let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
      let totObj := mkTotalsJv (n 2) (n 3) (n 4) (n 5) (n 6) (n 7) (n 8)
      let totPairs := totObj.asObj?.getD #[]
      out := out.push (.obj (#[
        ("key", .str effMdl),
        ("label", .str effMdl),
        ("model", .str effMdl),
        ("provider", if prov.isEmpty || prov == "unknown" then .null else .str prov),
        ("source", .str "router")
      ] ++ totPairs))
  return out

def buildAiUsageSummaryJson (store : CoreStore) (qMap : Array (String × String))
    (callerUserId : String := "") (effAdmin : Bool := true) : IO JVal := do
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let win := ((qParam? qMap "window").getD "24h").trimAscii.toString
  let compact := ((qParam? qMap "compact").getD "false") == "true"
  let topLimit := Nat.min 50 (Nat.max 1 (((qParam? qMap "top_limit").bind String.toNat?).getD 10))
  let winSecs? := parseWindowSeconds? win
  let winStartIso? := winSecs?.map (fun s => formatEpochIso8601Utc (if nowSec > s then nowSec - s else 0))
  let scopeSql := callerUsageScope callerUserId effAdmin
  let sinceJv : JVal := match winStartIso? with | some s => .str s | none => .null
  let dayStartSec := (nowSec / 86400) * 86400
  let todayIso := formatEpochIso8601Utc dayStartSec
  let weekIso := formatEpochIso8601Utc (if nowSec > 604800 then nowSec - 604800 else 0)

  let totals ← queryTotalsSince store winStartIso? scopeSql
  let todayTotals ← queryTotalsSince store (some todayIso) scopeSql
  let weekTotals ← queryTotalsSince store (some weekIso) scopeSql
   let byProvider ← queryGroupedUsageBuckets store "COALESCE(NULLIF(provider,''),'unknown')" winStartIso? topLimit (scopeSql := scopeSql)
  let byModel ← queryModelUsageBuckets store winStartIso? topLimit scopeSql
   let byAccount ← queryGroupedUsageBuckets store "COALESCE(NULLIF(account_id,''),'unattributed')" winStartIso? topLimit (scopeSql := scopeSql)
   let byCaller ← queryGroupedUsageBuckets store "COALESCE(NULLIF(caller_kind,''),'mission')" winStartIso? topLimit (scopeSql := scopeSql)
   let byPurpose ← queryGroupedUsageBuckets store "COALESCE(NULLIF(purpose,''),'turn')" winStartIso? topLimit (scopeSql := scopeSql)
  let byMissionAll ← queryGroupedUsageBuckets store "COALESCE(NULLIF(mission_id,''),'')" winStartIso? 1000
    (nullKeyVal := none) (nullLabelVal := none) (scopeSql := scopeSql)
  let byMission := byMissionAll.toList.take topLimit |>.toArray
  let byRootMission ← rollupByRootMission store byMissionAll topLimit

  let (wSql, dArgs) := match winStartIso? with
    | some s => (s!"WHERE timestamp >= ?1{scopeSql}", #[s])
    | none => (if scopeSql.isEmpty then "" else s!"WHERE 1=1{scopeSql}", #[])
  let effWhere := if winStartIso?.isSome then wSql else if scopeSql.isEmpty then "" else s!"WHERE 1=1{scopeSql}"
  let dayLimit : Nat :=
    match winSecs? with
    | some s => Nat.min 366 (Nat.max 1 ((s.toNat + 86399) / 86400 + 1))
    | none => 14
  let mut dayCallers : Array (String × Array (String × JVal)) := #[]
  if let .ok dcrs ← execParamQuery store.missionsDb
      s!"SELECT substr(timestamp,1,10) AS d, COALESCE(NULLIF(caller_kind,''),'mission') AS ck, COUNT(*) FROM proxy_usage {effWhere} GROUP BY d, ck;"
      dArgs then
    for i in [1:dcrs.size] do
      let r := dcrs[i]!
      let d := ((r[0]?).getD "").trimAscii.toString
      let ck := ((r[1]?).getD "mission").trimAscii.toString
      let c := ((r[2]?).bind String.toNat?).getD 0
      if !d.isEmpty && c > 0 then
        match dayCallers.findIdx? (fun (dk, _) => dk == d) with
        | some idx =>
          let (_, cur) := dayCallers[idx]!
          dayCallers := dayCallers.set! idx (d, cur.push (ck, JVal.nat c))
        | none =>
          dayCallers := dayCallers.push (d, #[(ck, JVal.nat c)])

  let mut byDay : Array JVal := #[]
  if let .ok drs ← execParamQuery store.missionsDb
      s!"SELECT substr(timestamp,1,10) AS d, COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage {effWhere} GROUP BY d ORDER BY d DESC LIMIT {dayLimit};"
      dArgs then
    for i in [1:drs.size] do
      let r := drs[i]!
      let dKey := ((r[0]?).getD "")
      let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
      let dayTot := mkTotalsJv (n 1) (n 2) (n 3) (n 4) (n 5) (n 6) (n 7)
      let dayPairs := dayTot.asObj?.getD #[]
      let ckPairs := (dayCallers.find? (fun (dk, _) => dk == dKey)).map (·.2) |>.getD #[]
      byDay := byDay.push (.obj (#[
        ("day", .str dKey),
        ("router_requests", JVal.nat (n 1)),
        ("by_caller_kind", .obj ckPairs),
        ("totals", dayTot)
      ] ++ dayPairs))

  let mut byHour : Array JVal := #[]
  let mut recent : Array JVal := #[]
  if !compact then
    let mut hourCallers : Array (String × Array (String × JVal)) := #[]
    if let .ok hcrs ← execParamQuery store.missionsDb
        s!"SELECT substr(timestamp,1,13) AS h, COALESCE(NULLIF(caller_kind,''),'mission') AS ck, COUNT(*) FROM proxy_usage {effWhere} GROUP BY h, ck;"
        dArgs then
      for i in [1:hcrs.size] do
        let r := hcrs[i]!
        let h := ((r[0]?).getD "").trimAscii.toString
        let ck := ((r[1]?).getD "mission").trimAscii.toString
        let c := ((r[2]?).bind String.toNat?).getD 0
        if !h.isEmpty && c > 0 then
          match hourCallers.findIdx? (fun (hk, _) => hk == h) with
          | some idx =>
            let (_, cur) := hourCallers[idx]!
            hourCallers := hourCallers.set! idx (h, cur.push (ck, JVal.nat c))
          | none =>
            hourCallers := hourCallers.push (h, #[(ck, JVal.nat c)])
    if let .ok hrs ← execParamQuery store.missionsDb
        s!"SELECT substr(timestamp,1,13) AS h, COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage {effWhere} GROUP BY h ORDER BY h DESC LIMIT 168;"
        dArgs then
      for i in [1:hrs.size] do
        let r := hrs[i]!
        let hKey := ((r[0]?).getD "")
        let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
        let hourTot := mkTotalsJv (n 1) (n 2) (n 3) (n 4) (n 5) (n 6) (n 7)
        let hourPairs := hourTot.asObj?.getD #[]
        let ckPairs := (hourCallers.find? (fun (hk, _) => hk == hKey)).map (·.2) |>.getD #[]
        byHour := byHour.push (.obj (#[
          ("hour", .str hKey),
          ("router_requests", JVal.nat (n 1)),
          ("by_caller_kind", .obj ckPairs)
        ] ++ hourPairs))
    if let .ok rrs ← execParamQuery store.missionsDb
        s!"SELECT timestamp, COALESCE(mission_id,''), COALESCE(provider,''), COALESCE(account_id,''), model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, cost_cents, COALESCE(caller_kind,''), COALESCE(purpose,'') FROM proxy_usage {effWhere} ORDER BY id DESC LIMIT 25;"
        dArgs then
      for i in [1:rrs.size] do
        let r := rrs[i]!
        let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
        let inp := n 5; let outT := n 6; let cr := n 7; let cc := n 8; let re := n 9; let cost := n 10
        let mid := (r[1]?).getD ""
        let aid := (r[3]?).getD ""
        recent := recent.push (.obj #[
          ("timestamp", .str ((r[0]?).getD nowIso)),
          ("source", .str "proxy"),
          ("mission_id", if mid.isEmpty then .null else .str mid),
          ("mission_title", .null),
          ("backend", .str "proxy"),
          ("provider", .str ((r[2]?).getD "unknown")),
          ("account_id", if aid.isEmpty then .null else .str aid),
          ("account_label", .null),
          ("account_bound", .bool (!aid.isEmpty)),
          ("model", .str ((r[4]?).getD "")),
          ("api_key_id", .null),
          ("api_key_name", .null),
          ("caller_kind", .str ((r[11]?).getD "mission")),
          ("purpose", .str ((r[12]?).getD "turn")),
          ("input_tokens", JVal.nat inp),
          ("output_tokens", JVal.nat outT),
          ("cache_read_tokens", JVal.nat cr),
          ("cache_creation_tokens", JVal.nat cc),
          ("reasoning_tokens", JVal.nat re),
          ("total_tokens", JVal.nat (inp + outT + cr + cc + re)),
          ("recorded_cost_cents", JVal.nat cost),
          ("estimated_cost_cents", JVal.nat cost)
        ])

  let totPairs := totals.asObj?.getD #[]
  let bySource : Array JVal :=
    if totals.fieldNat? "events" == some 0 then #[]
    else #[.obj (#[("key", .str "router"), ("label", .str "Router")] ++ totPairs)]
  let byRoute : Array JVal :=
    if totals.fieldNat? "events" == some 0 then #[]
    else #[.obj (#[("key", .str "proxy"), ("label", .str "Proxy")] ++ totPairs)]

  return .obj #[
    ("window", .str win),
    ("window_start", sinceJv),
    ("since", sinceJv),
    ("generated_at", .str nowIso),
    ("totals", totals),
    ("today", todayTotals),
    ("this_week", weekTotals),
    ("by_source", .arr bySource),
    ("by_route", .arr byRoute),
    ("by_backend", .arr #[]),
    ("by_provider", .arr byProvider),
    ("by_account", .arr byAccount),
    ("by_model", .arr byModel),
    ("by_api_key", .arr #[]),
    ("by_caller_kind", .arr byCaller),
    ("by_purpose", .arr byPurpose),
    ("by_mission", .arr byMission),
    ("by_root_mission", .arr byRootMission),
    ("by_day", .arr byDay),
    ("by_hour", .arr byHour),
    ("recent", .arr recent),
    ("filters_available", .obj #[
      ("backends", .arr #[.str "claudecode", .str "codex", .str "opencode", .str "antigravity"]),
      ("providers", .arr (byProvider.filterMap (fun b => b.field? "key"))),
      ("models", .arr (byModel.filterMap (fun b => b.field? "key"))),
      ("caller_kinds", .arr (byCaller.filterMap (fun b => b.field? "key"))),
      ("api_keys", .arr #[])
    ])
  ]

/-! ## CLIProxy Login Flow (`/api/ai/providers/cli-proxy-login*`) -/

private def mapLoginSlug (raw : String) : Option (String × String × String) :=
  match raw.trimAscii.toString.toLower with
  | "anthropic" | "claude" => some ("anthropic", "claude", "redirect")
  | "openai" | "codex" => some ("codex", "codex", "redirect")
  | "xai" | "grok" => some ("xai", "xai", "device")
  | "kimi" => some ("kimi", "kimi", "device")
  | "antigravity" => some ("antigravity", "antigravity", "redirect")
  | "muse-code" | "meta" => some ("meta", "meta", "redirect")
  | _ => none

/-- The last usage probe of this account was refused for authentication. -/
def loginRejected (hub : ProviderRuntimeHub) (providerId : String) : IO Bool := do
  let entries ← hub.mu.atomically (do return (← get).usageEntries)
  return (entries.find? (fun e => e.providerId == providerId)).any
    (fun e => e.payload.fieldStr? "status" == some "needs_reauth")

/-- The login of this provider is known to be refused: by its last usage probe, or by the
    last real request the proxy sent with it. When CLIProxyAPI holds the login the proxy's
    evidence is per provider type (`cliproxyapi:<type>`): it reports a refusal only when no
    login of that type could serve, and one success clears it. -/
def loginRejectedFor (hub : ProviderRuntimeHub) (store : CoreStore) (hp : HydratedProvider) : IO Bool := do
  if ← loginRejected hub hp.id then return true
  let viaCliProxy := hp.hasOAuth && !hp.hasApiKey
  match ← execParamQuery store.missionsDb
      "SELECT 1 FROM provider_auth_health WHERE account_key=?1 OR (?2<>'' AND account_key=?2) LIMIT 1;"
      #[hp.id, if viaCliProxy then s!"cliproxyapi:{hp.providerType}" else ""] with
  | .ok rows => return rows.size > 1
  | .error _ => return false

def reconcileCliLoginCompletion
    (hub : ProviderRuntimeHub) (store : CoreStore) (workingDir : String)
    (cooldowns : IO.Ref (Array AccountCooldown)) (tracker? : Option ProviderHealthTracker)
    (sess : CliLoginSession) (now : UInt64) : IO CliLoginSession := do
  if sess.status == "completed" || sess.status == "failed" then return sess
  let started := sess.completionStartedSec?.getD now
  let files ← scanCliProxyAuthFiles
  let providers ← loadHydratedProviders store workingDir
  let target? := sess.targetProvId?.bind (fun id => providers.find? (fun hp => hp.id == id))
  let targetTypeUnique (hp : HydratedProvider) : Bool :=
    (files.filter (fun f => !f.disabled && !f.accessToken.isEmpty && providerTypeMatchesAuthType hp.providerType f.authType)).size == 1
  let candidate (f : CliAuthFileInfo) : Bool :=
    f.authType == sess.authFileType && !f.disabled && !f.accessToken.isEmpty &&
    !(sess.beforeFiles.contains (f.fileName, f.fingerprint)) &&
    match sess.routedFile?, target? with
    | some file, some hp => f.fileName == file && hp.oauthFile == file
    | some _, none => false
    | none, none => true
    | none, some hp =>
      let typeOk := providerTypeMatchesAuthType hp.providerType f.authType
      let idOk := f.prefixId == hp.id || f.accountId == hp.id
      let emailOk := !hp.accountEmail.isEmpty && !f.email.isEmpty && hp.accountEmail.toLower == f.email.toLower
      let sidecarOk := targetTypeUnique hp &&
        (f.prefixId == s!"cliproxyapi:{hp.providerType}" || f.accountId == s!"cliproxyapi:{hp.providerType}" ||
          f.prefixId.isEmpty && f.accountId.isEmpty)
      typeOk && (idOk || emailOk || sidecarOk)
  let visible := files.any candidate
  let mut result := { sess with status := "completing", completionStartedSec? := some started }
  if visible then
    let affected := match target? with
      | some hp => #[hp]
      | none => providers.filter (fun hp => providerTypeMatchesAuthType hp.providerType sess.authFileType)
    let ids := affected.map (·.id)
    hub.mu.atomically do
      modify fun st => { st with
        usageGeneration := st.usageGeneration + 1
        usageEntries := (st.usageEntries.filter (fun e => !ids.contains e.providerId)).map (fun e => { e with refreshing := false })
      }
    let providerType := (affected[0]?.map (·.providerType)).getD
      (if sess.authFileType == "claude" then "anthropic" else if sess.authFileType == "codex" then "openai" else sess.authFileType)
    let typeKey := s!"cliproxyapi:{providerType}"
    let typePrefix := s!"{typeKey}:"
    let oauthRowIds := (affected.filter (fun hp => hp.hasOAuth && !hp.hasApiKey)).map (·.id)
    let matchesLoginKey (k : String) : Bool :=
      k == typeKey || k.startsWith typePrefix || oauthRowIds.contains k
    discard <| execParamQuery store.missionsDb
      "DELETE FROM provider_auth_health WHERE account_key=?1 OR substr(account_key, 1, length(?2))=?2;"
      #[typeKey, typePrefix]
    for k in oauthRowIds do
      discard <| execParamQuery store.missionsDb "DELETE FROM provider_auth_health WHERE account_key=?1;" #[k]
    cooldowns.modify (fun cs => cs.filter (fun c => !matchesLoginKey c.accountId))
    if let some tracker := tracker? then clearAccountHealthWhere tracker matchesLoginKey
    for hp in affected do
      refreshProviderUsageAsync hub hp
    result := { result with status := "completed", message? := some "Connected" }
    appendProviderAuditLog store sess.userId "" "login_complete" (sess.targetProvId?.getD "")
      #[s!"provider_type:{sess.providerSlug}"] (formatEpochIso8601Utc now)
  else if now >= started + 60 then
    result := { result with status := "failed", message? := some "Authentication completed but the new auth file was not visible within 60 seconds. Try reconnecting again." }
  hub.mu.atomically do
    modify fun st => { st with loginSessions := st.loginSessions.map (fun s => if s.sessionId == sess.sessionId then result else s) }
  return result

private def changedLoginRoute? (store : CoreStore) (sess : CliLoginSession) :
    IO (Option (Nat × String × ByteArray)) := do
  let some account := sess.targetProvId? | return none
  match ← AccountVpnRoutes.checkGeneration store.missionsDb account sess.routeGeneration with
  | .ok () => return none
  | .error "vpn_route_changed" => return some (jsonErr 409 "The account connection changed. Start sign-in again.")
  | .error _ => return some (jsonErr 503 "VPN route storage unavailable")

private def loginSessionResponse (sess : CliLoginSession) : Nat × String × ByteArray :=
  jsonResp 200 (.obj #[("status", .str sess.status), ("auth_url", .str sess.authUrl),
    ("message", sess.message?.map JVal.str |>.getD .null)])

private def cooldownReasonSlug : CooldownReason → String
  | .rateLimit   => "rate_limit"
  | .usageLimit  => "usage_limit"
  | .authFailure => "auth_failure"
  | .overloaded  => "overloaded"
  | .serverError => "server_error"

/-- Match an OAuth-only Core provider row to a single CLIProxyAPI auth file:
    - (a) Row email set and 1 OAuth-only row + 1 file of that type carry it: match.
    - (b) Otherwise, 1 OAuth-only row and 1 file of that type, and the file's email is empty or equal to the row's: match.
    - (c) 1 row, 1 file, both emails set and different: no match.
    - (d) Anything else: no match.
    Disabled files are skipped unless `includeDisabled`: health and enable/disable need to see a
    login the provider itself disabled, while cooldown clearing prefers a live file. -/
private def matchSidecarFileForProvider?
    (hps : Array HydratedProvider)
    (files : Array SidecarAuthFileEntry)
    (hp : HydratedProvider)
    (includeDisabled : Bool := false) : Option SidecarAuthFileEntry :=
  if !(hp.hasOAuth && !hp.hasApiKey) then none
  else
    let candidateFiles := if includeDisabled then files else files.filter (fun f => !f.disabled)
    let typeFiles := candidateFiles.filter (fun (f : SidecarAuthFileEntry) =>
      providerTypeMatchesAuthType hp.providerType f.provider)
    let oauthRows := hps.filter (fun (p : HydratedProvider) =>
      p.hasOAuth && !p.hasApiKey && p.providerType == hp.providerType)
    let rowEmail := hp.accountEmail.trimAscii.toString.toLower
    let emailRows :=
      if rowEmail.isEmpty then #[]
      else oauthRows.filter (fun (p : HydratedProvider) => p.accountEmail.trimAscii.toString.toLower == rowEmail)
    let emailFiles :=
      if rowEmail.isEmpty then #[]
      else typeFiles.filter (fun (f : SidecarAuthFileEntry) => f.email.trimAscii.toString.toLower == rowEmail)
    if !rowEmail.isEmpty && emailRows.size == 1 && emailFiles.size == 1 then
      emailFiles[0]?
    else if oauthRows.size == 1 && typeFiles.size == 1 then
      let f := typeFiles[0]!
      let fileEmail := f.email.trimAscii.toString.toLower
      if fileEmail.isEmpty || fileEmail == rowEmail then some f else none
    else
      none

/-- Reporting-only hint for a failed routing chain. Does not alter selection or recovery. -/
def sidecarLoginFailureMessage (store : CoreStore) (workingDir : String)
    (accounts : Array String) : IO (Option String) := do
  let hps ← loadHydratedProviders store workingDir
  let files ← fetchSidecarAuthFiles
  let affected := hps.filter fun hp =>
    (accounts.contains hp.id || accounts.any (fun k =>
      k == s!"cliproxyapi:{hp.providerType}" || k.startsWith s!"cliproxyapi:{hp.providerType}:")) &&
    (matchSidecarFileForProvider? hps files hp (includeDisabled := true)).any (·.needsReauth)
  if affected.isEmpty then return none
  let emails := affected.filterMap fun hp =>
    (matchSidecarFileForProvider? hps files hp (includeDisabled := true)).bind fun file =>
      if file.email.trimAscii.toString.isEmpty then none else some file.email.trimAscii.toString
  let identity := if emails.isEmpty then "the provider login" else String.intercalate ", " emails.toList
  return some s!"Sign in again for {identity}: the login is refresh-failed, expired or quota-exhausted. See Providers for the sidecar's reported reset."

/-- Clear a matched sidecar auth file's parked state by toggling `disabled: true` then `disabled: false`
    via `PATCH /v0/management/auth-files/status` (2-second timeout per call).
    - If `file.remainingSecs == 0`, returns `none` without making any sidecar PATCH calls.
    - If the first PATCH (`disabled: true`) fails or the management key is missing, returns `some (502, ...)`
      naming `providerId` and stating that the sidecar cooldown was not cleared and the login was not disabled.
    - If the second PATCH (`disabled: false`) fails, retries once; if still failing, returns `some (502, ...)`
      naming `providerId`, stating that the login was left disabled, and advising to re-enable it in CLIProxyAPI
      (never exposing the file name or email). -/
private def clearSidecarAuthFileCooldown (providerId : String) (file : SidecarAuthFileEntry) : IO (Option (Nat × String × ByteArray)) := do
  if file.disabled then
    return some (jsonErr 409 "Sign in again: the login is disabled; clearing cooldown cannot re-enable it")
  if file.remainingSecs == 0 then return none
  let mgmtBase ← resolveCliProxyBaseUrl
  let some mgmtKey ← resolveCliProxyMgmtKey?
    | return some (jsonErr 502 s!"Sidecar cooldown for provider {providerId} was not cleared and the login was not disabled")
  let url := s!"{mgmtBase}/v0/management/auth-files/status"
  let disableBody : JVal := .obj #[("name", .str file.name), ("disabled", .bool true)]
  let enableBody : JVal := .obj #[("name", .str file.name), ("disabled", .bool false)]
  match ← sendJsonRequest "PATCH" url (some mgmtKey) (some disableBody) #[] 2000 65536 with
  | .ok (c, _, _) =>
    if !(200 ≤ c && c < 300) then
      return some (jsonErr 502 s!"Sidecar cooldown for provider {providerId} was not cleared and the login was not disabled")
  | .error _ =>
    return some (jsonErr 502 s!"Sidecar cooldown for provider {providerId} was not cleared and the login was not disabled")
  let tryEnable : IO Bool := do
    match ← sendJsonRequest "PATCH" url (some mgmtKey) (some enableBody) #[] 2000 65536 with
    | .ok (c, _, _) => return (200 ≤ c && c < 300)
    | .error _ => return false
  if ← tryEnable then return none
  if ← tryEnable then return none
  return some (jsonErr 502 s!"CLIProxyAPI login for provider {providerId} was left disabled because re-enabling failed after retry; re-enable it in CLIProxyAPI")

/-- Set one CLIProxyAPI login's `disabled` flag through `PATCH /v0/management/auth-files/status`.
    Errors name only the Core provider id; file names and emails never appear in replies. -/
private def setSidecarAuthFileDisabled (providerId : String) (file : SidecarAuthFileEntry)
    (disabled : Bool) : IO (Option (Nat × String × ByteArray)) := do
  let mgmtBase ← resolveCliProxyBaseUrl
  let some mgmtKey ← resolveCliProxyMgmtKey?
    | return some (jsonErr 502 s!"CLIProxyAPI login for provider {providerId} was not updated")
  let body : JVal := .obj #[("name", .str file.name), ("disabled", .bool disabled)]
  match ← sendJsonRequest "PATCH" s!"{mgmtBase}/v0/management/auth-files/status"
      (some mgmtKey) (some body) #[] 2000 65536 with
  | .ok (c, _, _) =>
    if 200 ≤ c && c < 300 then return none
    else return some (jsonErr 502 s!"CLIProxyAPI login for provider {providerId} was not updated")
  | .error _ =>
    return some (jsonErr 502 s!"CLIProxyAPI login for provider {providerId} was not updated")

/-- Keep an OAuth-only Core provider row and its matched CLIProxyAPI auth file in sync:
    disabling the row disables the login, re-enabling restores it. Rows that do not map to a
    single sidecar file are left untouched. -/
def syncSidecarAuthFileDisabledForProvider
    (store : CoreStore) (workingDir : String) (providerId : String) (disabled : Bool) :
    IO (Option (Nat × String × ByteArray)) := do
  let hps ← loadHydratedProviders store workingDir
  match hps.find? (fun hp => hp.id == providerId) with
  | none => return none
  | some hp =>
    if !(hp.hasOAuth && !hp.hasApiKey) then return none
    else
      let files ← fetchSidecarAuthFiles
      match matchSidecarFileForProvider? hps files hp (includeDisabled := true) with
      | none => return none
      | some file =>
        if file.disabled == disabled then return none
        else setSidecarAuthFileDisabled providerId file disabled

/-- OpenAI-compatible model-list URL; preserve explicit API prefixes. -/
def customModelsUrl (baseUrl : String) : String := Id.run do
  let mut base := baseUrl.trimAscii.toString
  while base.endsWith "/" do base := (base.dropEnd 1).toString
  if base.endsWith "/models" then return base
  return base ++ "/models"

/-- Refresh only server-owned custom credentials. Persist allowlisted model metadata,
    retaining the last successful observation when an upstream is unavailable. -/
def refreshCustomModelDiscovery (store : CoreStore) (workingDir : String) (hub : ProviderRuntimeHub) : IO Unit := do
  let old ← readDataJsonFile workingDir store.rootDir "model-discovery.json"
  let mut connections := (old.fieldArr? "connections").getD #[]
  let stamp := formatEpochIso8601Utc (← nowEpoch)
  for hp in (← loadHydratedProviders store workingDir) do
    if hp.providerType == "custom" && hp.enabled && hp.hasApiKey && !hp.baseUrl.isEmpty then
      let pid := s!"custom:{hp.id}"
      let previous := (connections.find? (fun c => c.fieldStr? "provider_id" == some pid)).getD (.obj #[])
      let mut observation := previous.setField "provider_id" (.str pid)
        |>.setField "access_profile" (.str "api")
        |>.setField "checked_at" (.str stamp)
        |>.setField "status" (.str "failed")
        |>.setField "source" (.str "stale_discovery")
      let resolve := match hub.resolveTransport? with
        | some transport => transport hp.providerType hp.id
        | none => AccountVpnRoutes.resolve store.missionsDb hp.id fun _ => pure (.error "vpn_coordinator_unavailable")
      match ← sendJsonRequest "GET" (customModelsUrl hp.baseUrl) (some hp.apiKey) none #[] 5000 1048576 (some resolve) with
      | .ok (code, _, some doc) =>
        if 200 ≤ code && code < 300 then
          if let some rows := doc.fieldArr? "data" then
            let mut models : Array JVal := #[]
            for row in rows do
              let id := ((row.fieldStr? "id").getD "").trimAscii.toString
              if !id.isEmpty && customProviderModelAllowed hp.name hp.baseUrl id &&
                  customProviderModelAllowed hp.id hp.baseUrl id &&
                  !models.any (fun m => m.fieldStr? "id" == some id) then
                models := models.push (.obj #[("id", .str id), ("name", .str id)])
            observation := observation.setField "status" (.str "discovered")
              |>.setField "source" (.str "discovery")
              |>.setField "last_success" (.obj #[("observed_at", .str stamp),
                ("completeness", .str "complete"), ("models", .arr models)])
      | _ => pure ()
      connections := (connections.filter (fun c => c.fieldStr? "provider_id" != some pid)).push observation
  writeDataJsonFile workingDir store.rootDir "model-discovery.json"
    (.obj #[("schema_version", JVal.nat 1), ("connections", .arr connections)])

private def filterDiscoveryConnectionModels (hps : Array HydratedProvider) (c : JVal) : JVal :=
  let pid := (c.fieldStr? "provider_id").getD ""
  let matched? := hps.find? (fun hp =>
    hp.id == pid || s!"custom:{hp.id}" == pid || hp.providerType.toLower == pid.toLower ||
    customProviderName hp.name == customProviderName pid)
  let pName := (matched?.map (·.name)).getD pid
  let bUrl := (matched?.map (·.baseUrl)).getD ""
  let pId := (matched?.map (·.id)).getD pid
  let keepModel (m : JVal) : Bool :=
    let mid := (m.fieldStr? "id").getD ""
    customProviderModelAllowed pName bUrl mid && customProviderModelAllowed pId bUrl mid
  let c1 := match c.field? "last_success" with
    | some ls@(.obj _) =>
      match ls.fieldArr? "models" with
      | some ms => c.setField "last_success" (ls.setField "models" (.arr (ms.filter keepModel)))
      | none => c
    | _ => c
  match c1.fieldArr? "fallback_models" with
  | some fms => c1.setField "fallback_models" (.arr (fms.filter keepModel))
  | none => c1

/-! ## Unified Dispatcher for AI Providers, Proxy Analytics, Model-Routing Health/Test & Catalog -/

set_option maxHeartbeats 1200000 in
def dispatchProviderAndAiRoute
    (hub : ProviderRuntimeHub)
    (store : CoreStore)
    (workingDir : String)
    (serverPort : UInt16)
    (pacingTracker? : Option ProxyPacingTracker)
    (proxyCooldownsRef : IO.Ref (Array AccountCooldown))
    (method cleanPath rawTarget : String)
    (bodyBytes : ByteArray)
    (callerUserId : String)
    (isAdmin isLegacyUnscoped : Bool)
    (healthTracker? : Option ProviderHealthTracker := none)
    (probeBearer? : Option String := none) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let qMap := parseQueryMap rawTarget
  let effAdmin := isLegacyUnscoped || isAdmin
  -- The proxy records a login held by CLIProxyAPI under `cliproxyapi:<type>`, not the row id.
  let healthKeys (hp : HydratedProvider) : Array String :=
    if hp.hasOAuth && !hp.hasApiKey then #[hp.id, s!"cliproxyapi:{hp.providerType}"] else #[hp.id]

  -- 1. `GET /api/providers/antigravity-models` & `GET /api/antigravity-models` (300s cached!)
  if method == "GET" && (segs == ["api", "providers", "antigravity-models"] || segs == ["api", "antigravity-models"]) then
    if !effAdmin then return some (jsonResp 200 (.arr #[]))
    let force := ((qParam? qMap "force").getD "") == "true"
    let pairs ← getCachedAntigravityModels hub force
    let arr := pairs.map (fun (mId, mLbl) => JVal.arr #[.str mId, .str mLbl])
    return some (jsonResp 200 (.arr arr))

  -- 2. `GET /api/providers/{discovery,catalog,snapshots}` & `POST /api/providers/catalog/refresh`
  if segs == ["api", "providers", "discovery"] && method == "GET" then
    let disc ← readDataJsonFile workingDir store.rootDir "model-discovery.json"
    let rawRes := if disc.isNull then JVal.obj #[("schema_version", JVal.nat 1), ("connections", .arr #[])] else disc
    let hps ← loadHydratedProviders store workingDir
    let allConns := ((rawRes.fieldArr? "connections").getD #[]).map (filterDiscoveryConnectionModels hps)
    let res := rawRes.setField "connections" (.arr allConns)
    if effAdmin then
      return some (jsonResp 200 res)
    let conns := allConns.filterMap fun c =>
      let pid := (c.fieldStr? "provider_id").getD ""
      match hps.find? (fun hp => hp.enabled && (hp.hasApiKey || hp.hasOAuth) &&
          (hp.id == pid || hp.providerType.toLower == pid.toLower)) with
      | some hp => some (projectMemberProviderUsageJv c (memberProviderDisplayName hps hp))
      | none => none
    return some (jsonResp 200 (res.setField "connections" (.arr conns)))

  if segs == ["api", "providers", "catalog"] && method == "GET" then
    let hps ← loadHydratedProviders store workingDir
    let visibleHps := if effAdmin then hps else hps.filter (fun hp => hp.enabled && (hp.hasApiKey || hp.hasOAuth))
    let items := visibleHps.map (fun hp => JVal.obj #[
      ("id", .str hp.id),
      ("name", .str (if effAdmin then hp.name else memberProviderDisplayName hps hp)),
      ("provider_type", .str hp.providerType),
      ("enabled", .bool hp.enabled),
      ("has_credentials", .bool (hp.hasApiKey || hp.hasOAuth)),
      ("models", .arr hp.customModels)
    ])
    return some (jsonResp 200 (.obj #[("providers", .arr items)]))

  if segs == ["api", "providers", "snapshots"] && method == "GET" then
    return some (jsonResp 200 (.obj #[("snapshots", .arr #[])]))

  if segs == ["api", "providers", "catalog", "refresh"] && method == "POST" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    refreshCustomModelDiscovery store workingDir hub
    let _ ← getCachedAntigravityModels hub true
    let nowSec ← nowEpoch
    hub.mu.atomically do
      let st ← get
      set { st with catalogRefreshedSec := nowSec }
    return some (jsonResp 200 (.obj #[("ok", .bool true), ("refreshed_at", .str (formatEpochIso8601Utc nowSec))]))

  -- 3. `GET /api/ai/usage/summary`, `GET /api/ai/proxy/health`, `GET /api/ai/proxy/timing`
  if method == "GET" && segs == ["api", "ai", "usage", "summary"] then
    let summary ← buildAiUsageSummaryJson store qMap callerUserId effAdmin
    return some (jsonResp 200 summary)

  if method == "GET" && segs == ["api", "ai", "proxy", "health"] then
    let nowSec ← nowEpoch
    let nowIso := formatEpochIso8601Utc nowSec
    let win := ((qParam? qMap "window").getD "24h").trimAscii.toString
    let winSecs? := parseWindowSeconds? win
    let winStart? := winSecs?.map (fun s => formatEpochIso8601Utc (if nowSec > s then nowSec - s else 0))
    let sinceJv : JVal := match winStart? with | some s => .str s | none => .null
    let scopeSql := ""
    let (wSql, wArgs) := match winStart? with
      | some s => (s!"WHERE timestamp >= ?1{scopeSql}", #[s])
      | none => (if scopeSql.isEmpty then "" else s!"WHERE 1=1{scopeSql}", #[])
    let mut totalReqs : Nat := 0
    let mut okReqs : Nat := 0
    let mut failReqs : Nat := 0
    let mut retriedReqs : Nat := 0
    let mut totalRetries : Nat := 0
    let mut fallbackReqs : Nat := 0
    let mut recentFailures : Array JVal := #[]
    let mut groups : Array JVal := #[]
    let mut chains : Array JVal := #[]
    let mut totErrors : Array (String × JVal) := #[]
    let errorKeyFor (status : String) (httpStatus : Nat) : String :=
      let s := status.trimAscii.toString
      if s == "timeout" || s == "stalled" || s == "empty_before_first_chunk" ||
         s == "stream_incomplete" || s == "upstream_idle_timeout" || s == "idle_timeout" ||
         s.startsWith "client_error:" || s.startsWith "server_error:" then s
      else if httpStatus >= 400 && httpStatus < 500 then s!"client_error:{httpStatus}"
      else if httpStatus >= 500 then s!"server_error:{httpStatus}"
      else if s.isEmpty || s == "error" then "server_error:502"
      else s
    let rateOf (okCnt reqCnt : Nat) (zeroJv : JVal) : JVal :=
      if reqCnt == 0 then zeroJv
      else if okCnt == reqCnt then .num "1.0"
      else if okCnt == 0 then .num "0.0"
      else .num (toString (Float.ofNat okCnt / Float.ofNat reqCnt))
    let addErrCount (m : Array (String × Nat)) (k : String) (c : Nat) : Array (String × Nat) :=
      if c == 0 then m
      else
        match m.findIdx? (fun (ek, _) => ek == k) with
        | some idx =>
          let (_, prev) := m[idx]!
          m.set! idx (k, prev + c)
        | none =>
          m.push (k, c)
    if effAdmin then
      if let .ok ors ← execParamQuery store.missionsDb
          s!"SELECT COUNT(*), COALESCE(SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN status<>'ok' THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN retries>0 THEN 1 ELSE 0 END),0), COALESCE(SUM(retries),0), COALESCE(SUM(CASE WHEN fallback_depth>0 THEN 1 ELSE 0 END),0) FROM proxy_outcomes {wSql};"
          wArgs then
        if ors.size > 1 then
          totalReqs := ((ors[1]![0]?).bind String.toNat?).getD 0
          okReqs := ((ors[1]![1]?).bind String.toNat?).getD 0
          failReqs := ((ors[1]![2]?).bind String.toNat?).getD 0
          retriedReqs := ((ors[1]![3]?).bind String.toNat?).getD 0
          totalRetries := ((ors[1]![4]?).bind String.toNat?).getD 0
          fallbackReqs := ((ors[1]![5]?).bind String.toNat?).getD 0
      let errWhere := match winStart? with | some _ => "WHERE timestamp >= ?1 AND status<>'ok'" | none => "WHERE status<>'ok'"
      if let .ok ers ← execParamQuery store.missionsDb
          s!"SELECT status, COALESCE(http_status,0), COUNT(*) FROM proxy_outcomes {errWhere} GROUP BY status, COALESCE(http_status,0);"
          wArgs then
        let mut errMap : Array (String × Nat) := #[]
        for i in [1:ers.size] do
          let r := ers[i]!
          let k := errorKeyFor ((r[0]?).getD "error") (((r[1]?).bind String.toNat?).getD 0)
          let c := ((r[2]?).bind String.toNat?).getD 0
          errMap := addErrCount errMap k c
        totErrors := errMap.map (fun (k, c) => (k, JVal.nat c))
      let mut grpErrByKey : Array ((String × String × String) × Array (String × Nat)) := #[]
      if let .ok gers ← execParamQuery store.missionsDb
          s!"SELECT COALESCE(provider,''), COALESCE(model,''), COALESCE(account_id,''), status, COALESCE(http_status,0), COUNT(*) FROM proxy_outcomes {errWhere} GROUP BY COALESCE(provider,''), COALESCE(model,''), COALESCE(account_id,''), status, COALESCE(http_status,0);"
          wArgs then
        for i in [1:gers.size] do
          let r := gers[i]!
          let gKey := (((r[0]?).getD "").trimAscii.toString, ((r[1]?).getD "").trimAscii.toString, ((r[2]?).getD "").trimAscii.toString)
          let k := errorKeyFor ((r[3]?).getD "error") (((r[4]?).bind String.toNat?).getD 0)
          let c := ((r[5]?).bind String.toNat?).getD 0
          if c > 0 then
            match grpErrByKey.findIdx? (fun (gk, _) => gk == gKey) with
            | some idx =>
              let (_, prevMap) := grpErrByKey[idx]!
              grpErrByKey := grpErrByKey.set! idx (gKey, addErrCount prevMap k c)
            | none =>
              grpErrByKey := grpErrByKey.push (gKey, #[(k, c)])
      if let .ok grs ← execParamQuery store.missionsDb
          s!"SELECT COALESCE(provider,''), COALESCE(model,''), COALESCE(account_id,''), COUNT(*), COALESCE(SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN retries>0 THEN 1 ELSE 0 END),0) FROM proxy_outcomes {wSql} GROUP BY COALESCE(provider,''), COALESCE(model,''), COALESCE(account_id,'') ORDER BY COUNT(*) DESC;"
          wArgs then
        for i in [1:grs.size] do
          let r := grs[i]!
          let prov := ((r[0]?).getD "").trimAscii.toString
          let mdl := ((r[1]?).getD "").trimAscii.toString
          let acct := ((r[2]?).getD "").trimAscii.toString
          let gReqs := ((r[3]?).bind String.toNat?).getD 0
          let gOk := ((r[4]?).bind String.toNat?).getD 0
          let gRet := ((r[5]?).bind String.toNat?).getD 0
          let gErrMap :=
            match grpErrByKey.find? (fun (gk, _) => gk == (prov, mdl, acct)) with
            | some (_, em) => em
            | none => #[]
          groups := groups.push (.obj #[
            ("provider", if prov.isEmpty then .null else .str prov),
            ("model", if mdl.isEmpty then .null else .str mdl),
            ("account_id", if acct.isEmpty then .null else .str acct),
            ("requests", JVal.nat gReqs),
            ("ok", JVal.nat gOk),
            ("success_rate", rateOf gOk gReqs (.num "1.0")),
            ("ttft_p50_ms", .null),
            ("ttft_p95_ms", .null),
            ("latency_p50_ms", .null),
            ("latency_p95_ms", .null),
            ("retried", JVal.nat gRet),
            ("errors", .obj (gErrMap.map (fun (k, c) => (k, JVal.nat c)))),
            ("flags", .arr #[])
          ])
      let mut chnErrByKey : Array (String × Array (String × Nat)) := #[]
      if let .ok cers ← execParamQuery store.missionsDb
          s!"SELECT COALESCE(chain_id,''), status, COALESCE(http_status,0), COUNT(*) FROM proxy_outcomes {errWhere} GROUP BY COALESCE(chain_id,''), status, COALESCE(http_status,0);"
          wArgs then
        for i in [1:cers.size] do
          let r := cers[i]!
          let cidKey := ((r[0]?).getD "").trimAscii.toString
          let k := errorKeyFor ((r[1]?).getD "error") (((r[2]?).bind String.toNat?).getD 0)
          let c := ((r[3]?).bind String.toNat?).getD 0
          if c > 0 then
            match chnErrByKey.findIdx? (fun (ck, _) => ck == cidKey) with
            | some idx =>
              let (_, prevMap) := chnErrByKey[idx]!
              chnErrByKey := chnErrByKey.set! idx (cidKey, addErrCount prevMap k c)
            | none =>
              chnErrByKey := chnErrByKey.push (cidKey, #[(k, c)])
      if let .ok crs ← execParamQuery store.missionsDb
          s!"SELECT COALESCE(chain_id,''), COUNT(*), COALESCE(SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN retries>0 THEN 1 ELSE 0 END),0) FROM proxy_outcomes {wSql} GROUP BY COALESCE(chain_id,'') ORDER BY COUNT(*) DESC;"
          wArgs then
        for i in [1:crs.size] do
          let r := crs[i]!
          let cid := ((r[0]?).getD "").trimAscii.toString
          let cReqs := ((r[1]?).bind String.toNat?).getD 0
          let cOk := ((r[2]?).bind String.toNat?).getD 0
          let cRet := ((r[3]?).bind String.toNat?).getD 0
          let cErrMap :=
            match chnErrByKey.find? (fun (ck, _) => ck == cid) with
            | some (_, em) => em
            | none => #[]
          chains := chains.push (.obj #[
            ("chain_id", .str cid),
            ("requests", JVal.nat cReqs),
            ("ok", JVal.nat cOk),
            ("success_rate", rateOf cOk cReqs (.num "1.0")),
            ("ttft_p50_ms", .null),
            ("ttft_p95_ms", .null),
            ("latency_p50_ms", .null),
            ("latency_p95_ms", .null),
            ("retried", JVal.nat cRet),
            ("errors", .obj (cErrMap.map (fun (k, c) => (k, JVal.nat c))))
          ])
      if let .ok frs ← execParamQuery store.missionsDb
          "SELECT timestamp, chain_id, COALESCE(provider,''), COALESCE(account_id,''), COALESCE(model,''), status, COALESCE(http_status,0), retries, total_ms, fallback_depth FROM proxy_outcomes WHERE status<>'ok' ORDER BY id DESC LIMIT 20;"
          #[] then
        for i in [1:frs.size] do
          let r := frs[i]!
          recentFailures := recentFailures.push (.obj #[
            ("timestamp", .str ((r[0]?).getD nowIso)),
            ("chain_id", .str ((r[1]?).getD "")),
            ("provider", .str ((r[2]?).getD "")),
            ("account_id", .str ((r[3]?).getD "")),
            ("model", .str ((r[4]?).getD "")),
            ("status", .str ((r[5]?).getD "error")),
            ("http_status", JVal.nat (((r[6]?).bind String.toNat?).getD 502)),
            ("retries", JVal.nat (((r[7]?).bind String.toNat?).getD 0)),
            ("total_ms", JVal.nat (((r[8]?).bind String.toNat?).getD 0)),
            ("fallback_depth", JVal.nat (((r[9]?).bind String.toNat?).getD 0))
          ])
    let emptyPct : JVal := .obj #[("samples", JVal.nat 0), ("p50", .null), ("p95", .null), ("max", .null)]
    return some (jsonResp 200 (.obj #[
      ("window", .str win),
      ("window_start", sinceJv),
      ("since", sinceJv),
      ("generated_at", .str nowIso),
      ("totals", .obj #[
        ("requests", JVal.nat totalReqs),
        ("succeeded", JVal.nat okReqs),
        ("ok", JVal.nat okReqs),
        ("failed", JVal.nat failReqs),
        ("superseded", JVal.nat 0),
        ("retried_requests", JVal.nat retriedReqs),
        ("total_retries", JVal.nat totalRetries),
        ("retried", JVal.nat retriedReqs),
        ("fallback_requests", JVal.nat fallbackReqs),
        ("success_rate", rateOf okReqs totalReqs (.num "1.0")),
        ("by_status", .obj #[("ok", JVal.nat okReqs)]),
        ("errors", .obj totErrors),
        ("ttft_ms", emptyPct),
        ("total_ms", emptyPct),
        ("ttft_p50_ms", .null),
        ("ttft_p95_ms", .null),
        ("latency_p50_ms", .null),
        ("latency_p95_ms", .null)
      ]),
      ("groups", .arr groups),
      ("chains", .arr chains),
      ("by_chain", .arr chains),
      ("by_provider", .arr groups),
      ("recent_failures", .arr recentFailures)
    ]))

  if method == "GET" && segs == ["api", "ai", "proxy", "timing"] then
    if !isLegacyUnscoped && !callerUserId.isEmpty then
      return some (jsonErr 403 "timing_unavailable_in_multi_user_mode")
    let mins := Nat.min 1440 (Nat.max 1 (((qParam? qMap "minutes").bind String.toNat?).getD 60))
    let zeroQuant : JVal := .obj #[("p50", .null), ("p95", .null), ("p99", .null), ("max", .null)]
    return some (jsonResp 200 (.obj #[
      ("window_seconds", JVal.nat (mins * 60)),
      ("samples", .null),
      ("overall", .obj #[
        ("count", .null), ("errors", .null),
        ("auth_us", zeroQuant), ("resolve_ms", zeroQuant),
        ("connect_ms", zeroQuant), ("ttfb_ms", zeroQuant), ("total_ms", zeroQuant)
      ]),
      ("by_provider", .arr #[]),
      ("by_caller", .arr #[]),
      ("recent_slow", .arr #[])
    ]))

  -- 4. Model Routing Health & Chain Test (`/api/model-routing/health*`, `/api/model-routing/chains/:id/test`)
  if method == "GET" && segs == ["api", "model-routing", "health"] then
    let nowSec ← nowEpoch
    let hps ← loadHydratedProviders store workingDir
    -- Both Core owners of a cooldown (`proxyCooldownsRef` and `ProviderHealthTracker`),
    -- plus CLIProxyAPI's `/v0/management/auth-files` cooldowns for matched OAuth-only rows.
    let tracked ← match healthTracker? with
      | some t => snapshotActiveHealthCooldowns t nowSec
      | none => pure #[]
    let cooldowns := (← proxyCooldownsRef.get) ++ tracked
    let sidecarFiles ← fetchSidecarAuthFiles
    let usageCached ← hub.mu.atomically (do return (← get).usageEntries)
    let visibleHps := if effAdmin then hps else hps.filter (fun hp => hp.enabled && (hp.hasApiKey || hp.hasOAuth))
    let mut snaps : Array JVal := #[]
    for hp in visibleHps do
      let keys := healthKeys hp
      let coreCooldowns := cooldowns.filter (fun c => keys.contains c.accountId)
      let coreRem : UInt64 :=
        coreCooldowns.foldl (fun acc c => max acc (c.remainingSecs nowSec)) 0
      let coreReason? : Option String :=
        (coreCooldowns.foldl (fun (best : UInt64 × Option String) c =>
          let r := c.remainingSecs nowSec
          if r > best.1 then (r, some (cooldownReasonSlug c.reason)) else best) (0, none)).2
      let matchedSidecar? :=
        (matchSidecarFileForProvider? hps sidecarFiles hp).orElse
          (fun _ => matchSidecarFileForProvider? hps sidecarFiles hp (includeDisabled := true))
      let sidecarDisabled := (matchedSidecar?.map (·.disabled)).getD false
      let loginUnavailable := matchedSidecar?.any (·.needsReauth)
      let sidecarRem : UInt64 := if sidecarDisabled then 0 else (matchedSidecar?.map (·.remainingSecs)).getD 0
      let trackerRecs ← match healthTracker? with
        | some t => keys.mapM (lookupAccountHealthRecord t)
        | none => pure #[]
      let disabledRec? := trackerRecs.find? (fun r => r.disabledByProvider)
      let disabledByProvider := disabledRec?.isSome
      let disabledMessage : String :=
        match disabledRec? with
        | some r => if r.disabledMessage.trimAscii.toString.isEmpty then "Provider disabled this account" else r.disabledMessage
        | none => ""
      let cdRem : UInt64 := if disabledByProvider || sidecarDisabled then 0
        else if loginUnavailable then sidecarRem else max coreRem sidecarRem
      let (parkedUntilJv, parkedReasonJv, parkedSourceJv) : JVal × JVal × JVal :=
        if disabledByProvider then
          (.null, .str "disabled_by_provider", .str "provider")
        else if sidecarDisabled then
          (.null, .str "disabled", .str "sidecar")
        else if sidecarRem > 0 && (loginUnavailable || sidecarRem >= coreRem) then
          let uJv := match matchedSidecar?.bind (·.retryAt?) with
            | some iso => .str iso
            | none => .str (formatEpochIso8601Utc (nowSec + sidecarRem))
          let rJv := match matchedSidecar?.bind (·.reason?) with
            | some r => .str r
            | none => .str "credential_quota"
          (uJv, rJv, .str "sidecar")
        else if coreRem > 0 && !loginUnavailable then
          (.str (formatEpochIso8601Utc (nowSec + coreRem)),
           .str (coreReason?.getD "rate_limit"),
           .str "core")
        else
          (.null, .null, .null)
      let trackerFails : Nat :=
        trackerRecs.foldl (fun acc r => max acc (max r.transientStreak.toNat r.consecutiveTrips.toNat)) 0
      let parkedOrPoisoned : Bool :=
        loginUnavailable || disabledByProvider || sidecarDisabled || cdRem > 0 ||
        trackerRecs.any (fun r => r.parkedQuota || r.poisonedSub)
      let failCnt : Nat := max trackerFails (if parkedOrPoisoned then 1 else 0)
      let isDegraded : Bool := parkedOrPoisoned || failCnt > 0
      let isHealthy : Bool := !isDegraded
      let accountState : String :=
        if disabledByProvider then "disabled_by_provider"
        else if sidecarDisabled then "disabled"
        else if isDegraded then "degraded"
        else "healthy"
      let remQuota : JVal :=
        match usageCached.find? (fun u => u.providerId == hp.id) with
        | some u =>
          let wins := ((u.payload.field? "optimize").bind (fun o => o.fieldArr? "windows")).getD #[]
          match wins[0]?.bind (fun w => w.field? "pct_remaining") with
          | some v => v
          | none => .null
        | none => .null
      snaps := snaps.push (.obj #[
        ("account_id", .str hp.id),
        ("provider_id", .str hp.providerType),
        ("account_state", .str accountState),
        ("disabled", .bool (disabledByProvider || sidecarDisabled)),
        ("disabled_by_provider", .bool disabledByProvider),
        ("disabled_by_provider_message", if disabledByProvider then .str disabledMessage else .null),
         ("is_healthy", if usageCached.any (fun u => u.providerId == hp.id) then .bool isHealthy else .null),
        ("is_degraded", .bool isDegraded),
        ("ewma_ttft_ms", .null),
        ("ewma_tps", .null),
         ("remaining_quota_pct", remQuota),
        ("consecutive_failures", JVal.nat failCnt),
        ("cooldown_secs_remaining", JVal.uint64 cdRem),
        ("cooldown_remaining_secs", JVal.uint64 cdRem),
        ("parked_until", parkedUntilJv),
        ("parked_reason", parkedReasonJv),
        ("parked_source", parkedSourceJv),
        ("login_status", if loginUnavailable then .str "needs_reauth" else .null),
        ("login_reason_code", JVal.nat ((matchedSidecar?.map (fun (f : SidecarAuthFileEntry) => f.loginReason)).getD 0).toNat),
        ("login_message", if loginUnavailable then .str "Sign in again" else .null),
         ("sample_count", if usageCached.any (fun u => u.providerId == hp.id) then JVal.nat 1 else .null),
        ("antigravity_refusal", .null)
      ])
    return some (jsonResp 200 (.arr snaps))

  if method == "POST" && segs.length == 5 && segs[0]? == some "api" && segs[1]? == some "model-routing" && segs[2]? == some "health" && segs[4]? == some "clear" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let acctId := segs[3]!
    let hps ← loadHydratedProviders store workingDir
    let matchedProv? := hps.find? (fun hp => hp.id == acctId)
    let keys := match matchedProv? with
      | some hp => healthKeys hp
      | none => #[acctId]
    let cur ← proxyCooldownsRef.get
    proxyCooldownsRef.set (cur.filter (fun c => !keys.contains c.accountId))
    if let some t := healthTracker? then clearAccountHealthWhere t keys.contains
    if let some hp := matchedProv? then
      let sidecarFiles ← fetchSidecarAuthFiles
      -- Recovery retains enabled-only matching even when reporting also sees old disabled files.
      let recoveryFile? := (matchSidecarFileForProvider? hps sidecarFiles hp).orElse
        fun _ => matchSidecarFileForProvider? hps sidecarFiles hp (includeDisabled := true)
      if let some file := recoveryFile? then
        if let some errResp ← clearSidecarAuthFileCooldown hp.id file then
          return some errResp
    return some (204, "text/plain", ByteArray.empty)

  -- The chain id may contain a slash (`builtin/smart`), so it is every segment between `chains` and `test`.
  if method == "POST" && segs.length >= 5 && segs[0]? == some "api" && segs[1]? == some "model-routing" && segs[2]? == some "chains" && segs.getLast? == some "test" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let rawId := String.intercalate "/" ((segs.drop 3).take (segs.length - 4))
    let cid := (percentDecodeStrict rawId).getD rawId
    let testAll := ((qParam? qMap "all").getD "false") == "true"
    let probeModel := if cid.startsWith "builtin/" then cid else s!"builtin/{cid}"
    let probeBody : JVal := .obj #[
      ("model", .str probeModel),
      ("max_tokens", JVal.nat 4),
      ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "ping")]])
    ]
    let t0 ← IO.monoMsNow
    match ← sendJsonRequest "POST" s!"http://127.0.0.1:{serverPort}/v1/chat/completions"
        probeBearer? (some probeBody) #[] 15000 262144 with
    | .ok (code, _, jv?) =>
      let dt := (← IO.monoMsNow) - t0
      let okBool := 200 ≤ code && code < 300
      if testAll then
        return some (jsonResp 200 (.obj #[
          ("ok", .bool okBool),
          ("entries_total", JVal.nat 1),
          ("entries_live", JVal.nat (if okBool then 1 else 0)),
          ("entries", .arr #[.obj #[
            ("provider_id", .str cid),
            ("model_id", .str probeModel),
            ("ok", .bool okBool),
            ("status", JVal.nat code),
            ("latency_ms", JVal.nat dt)
          ]])
        ]))
      else
        return some (jsonResp 200 (.obj #[
          ("ok", .bool okBool),
          ("status", JVal.nat code),
          ("response", jv?.getD .null)
        ]))
    | .error e =>
      return some (jsonResp 200 (.obj #[("ok", .bool false), ("status", JVal.nat 502), ("error", .str e)]))

  -- 5. `/api/ai/providers*` Sub-Routes & Rich List/Get
  if segs.length >= 3 && segs[0]? == some "api" && segs[1]? == some "ai" && segs[2]? == some "providers" then
    -- 5a. `GET /api/ai/providers` (Hydrated rich `ProviderResponse[]` when legacy `.sandboxed-sh/ai_providers.json` or CLIProxy auth files exist!)
    if method == "GET" && segs.length == 3 then
      let hasLegacyJson ← (System.FilePath.mk s!"{workingDir}/.sandboxed-sh/ai_providers.json").pathExists
      let hasStoreJson ← (System.FilePath.mk s!"{store.rootDir}/ai_providers.json").pathExists
      let authFiles ← scanCliProxyAuthFiles
      if !hasLegacyJson && !hasStoreJson && authFiles.isEmpty then
        return none
      let hps ← loadHydratedProviders store workingDir
      let uPrefs ← if isLegacyUnscoped then pure #[] else getUserProviderPrefs store callerUserId
      let usernames ← listUsernamesById store
      let sidecarFiles ← fetchSidecarAuthFiles
      let mut arr : Array JVal := #[]
      for hp in hps do
        if effAdmin || providerAddedBy hp callerUserId || (hp.enabled && (hp.hasApiKey || hp.hasOAuth)) then
          let uEn? := if isLegacyUnscoped then none else some (isUserProviderEnabled uPrefs hp.id)
          let rejected ← loginRejectedFor hub store hp
          let rejected := rejected ||
            (matchSidecarFileForProvider? hps sidecarFiles hp (includeDisabled := true)).any (·.needsReauth)
          let obs? ← match pacingTracker? with
            | some tr => if effAdmin then lookupObservedKeyRpm? tr hp.id else pure none
            | none => pure none
          arr := arr.push (renderHydratedProviderForCaller hps hp effAdmin callerUserId usernames uEn? obs? rejected)
      return some (jsonResp 200 (.arr arr))

    -- 5b. `GET /api/ai/providers/usage`
    if method == "GET" && segs == ["api", "ai", "providers", "usage"] then
      let nowSec ← nowEpoch
      let hps ← loadHydratedProviders store workingDir
      let cached ← hub.mu.atomically (do return (← get).usageEntries)
      let mut entryPairs : Array (String × JVal) := #[]
      for hp in hps do
        if hp.enabled && (hp.hasApiKey || hp.hasOAuth) then
          match cached.find? (fun e => e.providerId == hp.id) with
          | some hit =>
            let rawUsage := decorateCachedUsage hit nowSec
            let projectedUsage :=
              if effAdmin || providerAddedBy hp callerUserId then rawUsage
              else projectMemberProviderUsageJv rawUsage (memberProviderDisplayName hps hp)
            entryPairs := entryPairs.push (hp.id, projectedUsage)
            -- Refresh in background if >= 120s old (skip OpenAI OAuth-only unless forced)
            let isCodexOAuthOnly := usageProbeOnDemandOnly hp
            if nowSec >= hit.fetchedSec + usageRefreshAfterSecs && !isCodexOAuthOnly then
              refreshProviderUsageAsync hub hp
          | none =>
            let isCodexOAuthOnly := usageProbeOnDemandOnly hp
            if !isCodexOAuthOnly then
              refreshProviderUsageAsync hub hp
      return some (jsonResp 200 (.obj #[
        ("entries", .obj entryPairs),
        ("refresh_after_seconds", JVal.nat usageRefreshAfterSecs.toNat)
      ]))

    -- 5c. `GET /api/ai/providers/types`
    if method == "GET" && segs == ["api", "ai", "providers", "types"] then
      let arr := allProviderTypes.map fun m =>
        JVal.obj #[
          ("id", .str m.id),
          ("name", .str m.name),
          ("uses_oauth", .bool m.usesOAuth),
          ("env_var", match m.envVar? with | some ev => .str ev | none => .null)
        ]
      return some (jsonResp 200 (.arr arr))

    -- 5d. `POST /api/ai/providers/reorder`
    if method == "POST" && segs == ["api", "ai", "providers", "reorder"] then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "Invalid JSON")
      let ids := ((reqJv.fieldArr? "ids").getD #[]).filterMap JVal.asStr?
      for idx in [0:ids.size] do
        let _ ← execParamStmt store.missionsDb
          "UPDATE ai_providers SET sort_order=?2 WHERE id=?1;" #[ids[idx]!, toString idx]
      appendProviderAuditLog store callerUserId (if effAdmin then "admin" else "member") "reorder" "" #["sort_order"]
        (formatEpochIso8601Utc (← nowEpoch))
      let hps ← loadHydratedProviders store workingDir
      let usernames ← listUsernamesById store
      let visible := hps.filter (fun hp => effAdmin || providerAddedBy hp callerUserId || (hp.enabled && (hp.hasApiKey || hp.hasOAuth)))
      return some (jsonResp 200 (.arr (visible.map (fun hp => renderHydratedProviderForCaller hps hp effAdmin callerUserId usernames))))

    -- 5e. `GET /api/ai/providers/for-backend/:backend_id`
    if method == "GET" && segs.length == 5 && segs[3]? == some "for-backend" then
      let bid := segs[4]!.toLower
      if bid == "claudecode" then
        let hps ← loadHydratedProviders store workingDir
        match hps.find? (fun p => p.enabled && p.providerType.toLower == "anthropic" && (p.hasApiKey || p.hasOAuth)) with
        | some p =>
          let pName := if effAdmin then p.name else memberProviderDisplayName hps p
          return some (jsonResp 200 (.obj #[
            ("configured", .bool true),
            ("provider_type", .str "anthropic"),
            ("provider_name", .str pName),
            ("api_key", .null),
            ("oauth", .null),
            ("has_credentials", .bool true),
            ("auth_method", .str (if p.hasOAuth then "oauth" else "api_key"))
          ]))
        | none => pure ()
      return some (jsonResp 200 (.obj #[
        ("configured", .bool false),
        ("provider_type", .null),
        ("provider_name", .null),
        ("api_key", .null),
        ("oauth", .null),
        ("has_credentials", .bool false),
        ("auth_method", .null)
      ]))

    -- 5f. CLIProxy Login: `/api/ai/providers/cli-proxy-login[/:id[/callback]]`
    if segs.length >= 4 && segs[3]? == some "cli-proxy-login" then
      let mgmtBase ← resolveCliProxyBaseUrl
      let mgmtKey? ← resolveCliProxyMgmtKey?

      if method == "GET" && segs.length == 4 then
        let avail := mgmtKey?.isSome
        let mut provList : Array JVal := #[
          .obj #[("id", .str "mistral"), ("name", .str "Mistral Vibe")],
          .obj #[("id", .str "anthropic"), ("name", .str "Anthropic (Claude)")],
          .obj #[("id", .str "openai"), ("name", .str "OpenAI (Codex)")],
          .obj #[("id", .str "xai"), ("name", .str "xAI (Grok)")],
          .obj #[("id", .str "kimi"), ("name", .str "Kimi")],
          .obj #[("id", .str "antigravity"), ("name", .str "Antigravity")]
        ]
        if let some mk := mgmtKey? then
          if let .ok (200, _, some cfgJv) ← sendJsonRequest "GET" s!"{mgmtBase}/v0/management/config" (some mk) none #[] 2500 262144 then
            if !((cfgJv.fieldStr? "meta-api-key").getD "").isEmpty then
              provList := provList.push (.obj #[("id", .str "muse-code"), ("name", .str "Muse Code")])
        return some (jsonResp 200 (.obj #[("available", .bool avail), ("providers", .arr provList)]))

      -- Members may start and complete subscription logins for the shared pool (owner decision
      -- 2026-11-14); re-login of an existing account is limited to accounts they added.
      let some mgmtKey := mgmtKey?
        | return some (jsonErr 503 "CLIProxy management key is not configured on Core")

      if method == "POST" && segs.length == 4 then
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "Invalid JSON")
        let rawProv := (reqJv.fieldStr? "provider").getD ""
        let some (slug, authType, flow) := mapLoginSlug rawProv
          | return some (jsonErr 400 s!"Unsupported CLIProxy login provider `{rawProv}`")
        let targetProvId? := reqJv.fieldStr? "provider_id"
        if !effAdmin then
          if let some tid := targetProvId? then
            let some trow ← getAIProvider? store tid
              | return some (jsonErr 403 "not_account_owner")
            unless !callerUserId.isEmpty && trow.createdByUserId == callerUserId do
              return some (jsonErr 403 "not_account_owner")
        let beforeFiles := (← scanCliProxyAuthFiles).map (fun af => (af.fileName, af.fingerprint))
        let mut routedRequest? : Option JVal := none
        let mut routeGeneration : Nat := 0
        if let some account := targetProvId? then
          let .ok route ← AccountVpnRoutes.snapshot store.missionsDb account
            | return some (jsonErr 503 "VPN route storage unavailable")
          routeGeneration := route.generation
          if let .vpn _ := route then
            let accounts ← loadHydratedProviders store workingDir
            let some hp := accounts.find? (fun p => p.id == account)
              | return some (jsonErr 409 "VPN credential unavailable")
            let some url := hub.accountRelayUrl?.bind (fun sign => sign hp.providerType hp.id)
              | return some (jsonErr 503 "VPN relay unavailable")
            let file := accountRoutingFile accounts hp
            unless providerTypeMatchesAuthType hp.providerType authType && !file.isEmpty &&
                AccountVpnSidecar.validManagement mgmtBase &&
                (effAdmin || (!callerUserId.isEmpty && hp.createdByUserId == callerUserId)) do
              return some (jsonErr 403 "VPN credential ownership could not be verified")
            routedRequest? := some (.obj #[("provider", .str authType), ("name", .str file), ("proxy_url", .str url)])
        let login ← match routedRequest? with
          | some data => sendJsonRequest "POST" s!"{mgmtBase}/v8/management/oauth/auth-url" (some mgmtKey) (some data) #[] 15000 262144
          | none => sendJsonRequest "GET" s!"{mgmtBase}/v0/management/{slug}-auth-url" (some mgmtKey) none #[] 15000 262144
        match login with
        | .ok (code, rawTxt, some uJv) =>
          if 200 ≤ code && code < 300 then
            let authUrl := (uJv.fieldStr? "url").getD ""
            let stTok := (uJv.fieldStr? "state").getD ""
            if authUrl.isEmpty || stTok.isEmpty then
              return some (jsonErr 502 "CLIProxy returned incomplete auth URL response")
            let routedFile? := routedRequest?.bind (fun data => data.fieldStr? "name")
            if routedFile?.isSome && uJv.fieldStr? "target_auth_id" != routedFile? then
              return some (jsonErr 502 "Sidecar did not confirm the requested OAuth credential.")
            let sid ← newUuidV4
            let nowSec ← nowEpoch
            let sess : CliLoginSession := {
              sessionId := sid, providerSlug := slug, authFileType := authType,
              targetProvId? := targetProvId?, routedFile? := routedFile?, routeGeneration := routeGeneration, stateToken := stTok, authUrl := authUrl,
              flow := flow, createdSec := nowSec, beforeFiles := beforeFiles,
              userId := callerUserId
            }
            appendProviderAuditLog store callerUserId (if effAdmin then "admin" else "member") "login_start"
              (targetProvId?.getD "") #[s!"provider_type:{slug}"] (formatEpochIso8601Utc nowSec)
            hub.mu.atomically do
              let st ← get
              let kept := st.loginSessions.filter (fun s => nowSec ≤ s.createdSec + 900)
              set { st with loginSessions := kept.push sess }
            let instr :=
              if flow == "device" then "Open the authorization URL and complete device verification."
              else "Open the login link in your browser, sign in, and paste the callback URL if prompted."
            return some (jsonResp 200 (.obj #[
              ("session_id", .str sid),
              ("auth_url", .str authUrl),
              ("flow", .str flow),
              ("instructions", .str instr)
            ]))
          else
            if routedRequest?.isSome then
              return some (jsonErr 502 "Sidecar could not start a VPN-bound OAuth exchange. A sidecar with per-login OAuth proxy support is required.")
            return some (jsonErr 502 s!"CLIProxy auth-url failed: {rawTxt}")
        | _ => return some (jsonErr 502 "Failed reaching CLIProxy management endpoint")

      if segs.length == 5 then
        let sid := segs[4]!
        let nowSec ← nowEpoch
        let sess? ← hub.mu.atomically do
          let st ← get
          return st.loginSessions.find? (fun s => s.sessionId == sid && nowSec ≤ s.createdSec + 900)
        let some sess := sess?
          | return some (jsonErr 404 "Login session not found or expired")
        if !effAdmin && sess.userId != callerUserId then
          return some (jsonErr 404 "Login session not found or expired")

        if method == "DELETE" then
          let path := if sess.routedFile?.isSome then "/v8/management/oauth/session" else "/v0/management/oauth-session"
          let _ ← sendJsonRequest "DELETE" s!"{mgmtBase}{path}?state={urlEncodeComponent sess.stateToken}" (some mgmtKey) none #[] 5000 65536
          hub.mu.atomically do
            let st ← get
            set { st with loginSessions := st.loginSessions.filter (fun s => s.sessionId != sid) }
          return some (jsonResp 200 (.obj #[("status", .str "ok")]))

        if method == "GET" then
          if sess.status == "completed" || sess.status == "failed" then
            return some (loginSessionResponse sess)
          if let some failed ← changedLoginRoute? store sess then return some failed
          -- While not terminal, keep asking the sidecar even mid-completion: it accepts a
          -- callback before it exchanges the code, so only a later `error` reports why a
          -- wrong or expired callback URL will never produce a file. `ok` alone still
          -- never completes: that belongs to `reconcileCliLoginCompletion`'s visibility
          -- check.
          let path := if sess.routedFile?.isSome then "/v8/management/oauth/status" else "/v0/management/get-auth-status"
          match ← sendJsonRequest "GET" s!"{mgmtBase}{path}?state={urlEncodeComponent sess.stateToken}" (some mgmtKey) none #[] 8000 262144 with
          | .ok (200, _, some stJv) =>
            let stStr := ((stJv.fieldStr? "status").getD "wait").toLower
            if stStr == "error" then
              let errMsg := (stJv.fieldStr? "error").getD "Authentication failed"
              let failed := { sess with status := "failed", message? := some errMsg }
              hub.mu.atomically do
                modify fun st => { st with loginSessions := st.loginSessions.map (fun s => if s.sessionId == sess.sessionId then failed else s) }
              return some (loginSessionResponse failed)
            if let some file := sess.routedFile? then
              if stStr == "ok" && (stJv.fieldStr? "auth_id" != some file || stJv.fieldBool? "adopted" != some true) then
                return some (loginSessionResponse { sess with status := "failed", message? := some "Sidecar could not confirm the reconnected credential." })
            if (sess.routedFile?.isSome || sess.completionStartedSec?.isNone) && stStr != "ok" then
              return some (jsonResp 200 (.obj #[("status", .str "pending"), ("auth_url", .str sess.authUrl), ("message", .null)]))
          | _ =>
            if sess.routedFile?.isSome || sess.completionStartedSec?.isNone then
              return some (jsonResp 200 (.obj #[("status", .str sess.status), ("auth_url", .str sess.authUrl), ("message", .null)]))
          return some (loginSessionResponse (← reconcileCliLoginCompletion hub store workingDir proxyCooldownsRef healthTracker? sess nowSec))

      if method == "POST" && segs.length == 6 && segs[5]? == some "callback" then
        let sid := segs[4]!
        let nowSec ← nowEpoch
        let sess? ← hub.mu.atomically do
          let st ← get
          return st.loginSessions.find? (fun s => s.sessionId == sid && nowSec ≤ s.createdSec + 900)
        let some sess := sess?
          | return some (jsonErr 404 "Login session not found or expired")
        if !effAdmin && sess.userId != callerUserId then
          return some (jsonErr 404 "Login session not found or expired")
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "Invalid JSON")
        let rawCb := ((reqJv.fieldStr? "url").getD "").trimAscii.toString
        let cbQ := parseQueryMap rawCb
        let codeParam :=
          (qParam? cbQ "code").getD (
            match rawCb.splitOn "#" with
            | [c, _] => c
            | _ => rawCb)
        let stateParam :=
          (qParam? cbQ "state").getD (
            match rawCb.splitOn "#" with
            | [_, s] => s
            | _ => sess.stateToken)
        if stateParam != sess.stateToken then
          return some (jsonErr 400 "Callback state does not match login session")
        if let some failed ← changedLoginRoute? store sess then return some failed
        let cbPayload : JVal := .obj #[
          ("provider", .str (if sess.routedFile?.isSome then sess.authFileType else sess.providerSlug)),
          ("code", .str codeParam),
          ("state", .str stateParam)
        ]
        let path := if sess.routedFile?.isSome then "/v8/management/oauth/callback" else "/v0/management/oauth-callback"
        match ← sendJsonRequest "POST" s!"{mgmtBase}{path}" (some mgmtKey) (some cbPayload) #[] 15000 262144 with
        | .ok (c, _, _) =>
          if 200 ≤ c && c < 300 then
            if sess.routedFile?.isSome then return some (loginSessionResponse { sess with status := "completing" })
            return some (loginSessionResponse (← reconcileCliLoginCompletion hub store workingDir proxyCooldownsRef healthTracker? sess nowSec))
          return some (loginSessionResponse { sess with status := "failed", message? := some "CLIProxy rejected the callback" })
        | .error e =>
          return some (jsonResp 200 (.obj #[("status", .str "failed"), ("auth_url", .str sess.authUrl), ("message", .str e)]))

    -- 5g. Per-Provider Routes: `/api/ai/providers/:id[/{usage,default,health,reset-usage,antigravity/recheck,auth/methods}]`
    if segs.length >= 4 then
      let pidOrType := segs[3]!
      let hps ← loadHydratedProviders store workingDir
      let matchedProv? :=
        (hps.find? (fun p => p.id == pidOrType)).orElse fun _ =>
        hps.find? (fun p => p.providerType.toLower == pidOrType.toLower)

      -- `GET /api/ai/providers/:id`
      if method == "GET" && segs.length == 4 then
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        if !effAdmin && !providerAddedBy hp callerUserId && !(hp.enabled && (hp.hasApiKey || hp.hasOAuth)) then
          return some (jsonErr 404 "Provider not found")
        let rejected ← loginRejectedFor hub store hp
        let sidecarFiles ← fetchSidecarAuthFiles
        let rejected := rejected ||
          (matchSidecarFileForProvider? hps sidecarFiles hp (includeDisabled := true)).any (·.needsReauth)
        let usernames ← listUsernamesById store
        if effAdmin then
          let obs? ← match pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr hp.id
            | none => pure none
          return some (jsonResp 200 (renderHydratedProviderForCaller hps hp true callerUserId usernames none obs? rejected))
        else
          let uPrefs ← if isLegacyUnscoped then pure #[] else getUserProviderPrefs store callerUserId
          let uEn? := if isLegacyUnscoped then none else some (isUserProviderEnabled uPrefs hp.id)
          return some (jsonResp 200 (renderHydratedProviderForCaller hps hp false callerUserId usernames uEn? none rejected))

      -- `GET /api/ai/providers/:id/usage`
      if method == "GET" && segs.length == 5 && segs[4]? == some "usage" then
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        if !effAdmin && !providerAddedBy hp callerUserId && !(hp.enabled && (hp.hasApiKey || hp.hasOAuth)) then
          return some (jsonErr 404 "Provider not found")
        let force := ((qParam? qMap "force").getD "false") == "true"
        let cachedOnly := ((qParam? qMap "cached_only").getD "false") == "true"
        let nowSec ← nowEpoch
        let projectUsage (jv : JVal) : JVal :=
          if effAdmin || providerAddedBy hp callerUserId then jv else projectMemberProviderUsageJv jv (memberProviderDisplayName hps hp)
        if !force then
          let hit? ← hub.mu.atomically do
            let st ← get
            return st.usageEntries.find? (fun e => e.providerId == hp.id)
          if let some hit := hit? then
            if nowSec >= hit.fetchedSec + usageRefreshAfterSecs && !cachedOnly then
              refreshProviderUsageAsync hub hp
            return some (jsonResp 200 (projectUsage (decorateCachedUsage hit nowSec)))
        if cachedOnly then
          return some (jsonResp 200 (projectUsage (.obj #[
            ("provider_type", .str hp.providerType),
            ("provider_name", .str hp.name),
            ("account_email", if hp.accountEmail.isEmpty then .null else .str hp.accountEmail),
            ("status", .str "pending"),
            ("cached", .bool false)
          ])))
        let generation ← hub.mu.atomically (do return (← get).usageGeneration)
        let live ← probeProviderUsage hub hp
        let ts ← nowEpoch
        let tsIso := formatEpochIso8601Utc ts
        hub.mu.atomically do
          let st ← get
          if st.usageGeneration == generation then
            let others := st.usageEntries.filter (fun e => e.providerId != hp.id)
            set { st with usageEntries := others.push { providerId := hp.id, fetchedSec := ts, fetchedIso := tsIso, payload := live, refreshing := false } }
        return some (jsonResp 200 (projectUsage live))

      -- `POST /api/ai/providers/:id/default`
      if method == "POST" && segs.length == 5 && segs[4]? == some "default" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        writeDataJsonFile workingDir store.rootDir "default_provider.json" (.obj #[("default_provider_id", .str hp.id)])
        return some (jsonResp 200 (renderHydratedProviderJv { hp with isDefault := true }))

      -- `POST /api/ai/providers/:id/health`
      if method == "POST" && segs.length == 5 && segs[4]? == some "health" then
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        if !hp.hasApiKey && !hp.hasOAuth then
          return some (jsonResp 200 (.obj #[
            ("healthy", .bool false),
            ("status", .str "no_credentials"),
            ("message", .str "No credentials configured")
          ]))
        return some (jsonResp 200 (.obj #[
          ("healthy", .bool true),
          ("status", .str "connected"),
          ("message", .str "Provider credentials ready"),
          ("status_code", JVal.nat 200)
        ]))

      -- `POST /api/ai/providers/:id/reset-usage`
      if method == "POST" && segs.length == 5 && segs[4]? == some "reset-usage" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        return some (jsonResp 501 (.obj #[
          ("ok", .bool false),
          ("error", .str "unsupported"),
          ("message", .str "Vendor usage reset redemption is not implemented; no cooldown, grant, or mission state was changed."),
          ("provider_id", .str hp.id),
          ("reset_redeemed", .bool false),
          ("woken_missions", JVal.nat 0)
        ]))

      -- `POST /api/ai/providers/:id/antigravity/recheck`
      if method == "POST" && segs.length == 6 && segs[4]? == some "antigravity" && segs[5]? == some "recheck" then
        if !effAdmin then return some (jsonErr 403 "admin_required")
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        let cur ← proxyCooldownsRef.get
        proxyCooldownsRef.set (cur.filter (fun c => c.accountId != hp.id))
        let live ← probeProviderUsage hub hp
        return some (jsonResp 200 live)

      -- `GET /api/ai/providers/:id/auth/methods`
      if method == "GET" && segs.length == 6 && segs[4]? == some "auth" && segs[5]? == some "methods" then
        let pType := match matchedProv? with | some hp => hp.providerType | none => pidOrType
        let metaInfo := lookupProviderMeta pType
        let mut methods : Array JVal := #[]
        if metaInfo.usesOAuth then
          methods := methods.push (.obj #[("label", .str s!"{metaInfo.name} Subscription (OAuth)"), ("type", .str "oauth")])
        if metaInfo.envVar?.isSome || pType == "custom" then
          methods := methods.push (.obj #[("label", .str "API Key"), ("type", .str "api")])
        return some (jsonResp 200 (.arr methods))

  return none

end OrbCore.ProviderUsageAndLogin
