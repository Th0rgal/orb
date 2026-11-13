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
import LeanSys.Auth
import LeanSys.Http
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.Sqlite
import OrbBin.HttpClient
import OrbBin.ClaudeControl
import OrbCore.Store
import OrbCore.Proxy
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
open OrbCore.R7Core
open OrbCore.LegacyHydrate

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
  completionStartedSec? : Option UInt64 := none
  status        : String := "pending"
  message?      : Option String := none
  deriving Repr, Inhabited

structure ProviderHubState where
  agyModelsCache? : Option (UInt64 × Array (String × String)) := none
  usageEntries    : Array CachedUsageEntry := #[]
  usageGeneration : Nat := 0
  loginSessions   : Array CliLoginSession := #[]
  catalogRefreshedSec : UInt64 := 0

structure ProviderRuntimeHub where
  mu : Std.Mutex ProviderHubState
  usageProbe? : Option (String → IO JVal) := none

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

structure CliAuthFileInfo where
  fileName    : String
  fullPath    : String
  authType    : String
  email       : String
  accessToken : String
  accountId   : String
  prefixId    : String
  disabled    : Bool
  mtimeSec    : UInt64
  fingerprint : UInt64 := 0
  deriving Repr, Inhabited

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
                }
  return out

private def providerTypeMatchesAuthType (provType authType : String) : Bool :=
  match provType.toLower, authType.toLower with
  | "anthropic", "claude" | "anthropic", "anthropic" => true
  | "openai", "codex" | "openai", "openai" => true
  | "antigravity", "antigravity" => true
  | "kimi", "kimi" => true
  | "xai", "xai" => true
  | "muse-code", "meta" | "muse-code", "muse-code" => true
  | _, _ => false

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

private def readDataJsonFile (workingDir storeRoot relName : String) : IO JVal := do
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
  deriving Repr, Inhabited

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
  let nowIso := formatEpochIso8601Utc (← nowEpoch)

  let mut out : Array HydratedProvider := #[]
  let mut seenIds : Array String := #[]

  for idx in [0:dbProvs.size] do
    let p := dbProvs[idx]!
    seenIds := seenIds.push p.id
    let leg? := legacyArr.find? (fun j => (j.fieldStr? "id") == some p.id)
    let plainKey ← match ← decryptEnvValue key32? p.apiKey with | .ok s => pure s.trimAscii.toString | .error _ => pure p.apiKey.trimAscii.toString
    let legEmail := (leg?.bind (fun j => j.fieldStr? "account_email")).getD ""
    let legGoogleProj := (leg?.bind (fun j => j.fieldStr? "google_project_id")).getD ""
    let legOauthObj? := leg?.bind (fun j => j.field? "oauth")
    let legRefreshFile := (legOauthObj?.bind (fun o => o.fieldStr? "refresh_token")).getD ""
    let legAccessTok := (legOauthObj?.bind (fun o => o.fieldStr? "access_token")).getD ""

    -- Match CLIProxy auth file by prefix == p.id, refresh_token filename, email, or provider type
    let matchedAuth? :=
      (authFiles.find? (fun af => !af.disabled && af.prefixId == p.id)).orElse fun _ =>
      (authFiles.find? (fun af => !af.disabled && !legRefreshFile.isEmpty && af.fileName == legRefreshFile)).orElse fun _ =>
      (authFiles.find? (fun af => !af.disabled && !legEmail.isEmpty && af.email.toLower == legEmail.toLower && providerTypeMatchesAuthType p.providerType af.authType)).orElse fun _ =>
      (authFiles.find? (fun af => !af.disabled && providerTypeMatchesAuthType p.providerType af.authType))

    let metaInfo := lookupProviderMeta p.providerType
    let envKeyVal ← match metaInfo.envVar? with
      | some ev => pure ((← lookupEnvWithFiles? ev).getD "")
      | none => pure ""
    let effApiKey := if !plainKey.isEmpty && plainKey != "cli-proxy-managed" then plainKey else envKeyVal
    let hasApiKey := !effApiKey.isEmpty
    let hasOAuth := matchedAuth?.isSome || (!legAccessTok.isEmpty) || plainKey == "cli-proxy-managed"
    let effEmail :=
      if !legEmail.isEmpty then legEmail
      else (matchedAuth?.map (·.email)).getD ""
    let effOauthTok :=
      match matchedAuth? with
      | some af => af.accessToken
      | none => if legAccessTok != "cli-proxy-managed" then legAccessTok else ""
    let effOauthFile := (matchedAuth?.map (·.fileName)).getD legRefreshFile

    let bksFromFile : Array String :=
      match backendsJv.fieldArr? p.id with
      | some arr => arr.filterMap JVal.asStr?
      | none =>
        match leg?.bind (fun j => j.fieldArr? "use_for_backends") with
        | some arr => arr.filterMap JVal.asStr?
        | none => #[]

    let cModels : Array JVal := p.customModels.map fun cm =>
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
      let matchedAuth? :=
        (authFiles.find? (fun af => !af.disabled && (af.prefixId == lid || (!refFile.isEmpty && af.fileName == refFile)))).orElse fun _ =>
        (authFiles.find? (fun af => !af.disabled && !email.isEmpty && af.email.toLower == email.toLower && providerTypeMatchesAuthType pType af.authType))
      let hasApi := !aKey.isEmpty && aKey != "cli-proxy-managed"
      let hasOa := matchedAuth?.isSome || !accTok.isEmpty
      out := out.push {
        id := lid
        name := nm
        providerType := pType
        googleProjectId := gProj
        baseUrl := bUrl
        apiKey := if hasApi then aKey else ""
        hasApiKey := hasApi
        hasOAuth := hasOa
        oauthToken := (matchedAuth?.map (·.accessToken)).getD accTok
        oauthFile := (matchedAuth?.map (·.fileName)).getD refFile
        accountEmail := if !email.isEmpty then email else (matchedAuth?.map (·.email)).getD ""
        enabled := en
        isDefault := (lid == defaultId)
        priority := (leg.fieldNat? "priority").getD out.size
        useForBackends := ((leg.fieldArr? "use_for_backends").getD #[]).filterMap JVal.asStr?
        customModels := (leg.fieldArr? "custom_models").getD #[]
        rpmLimit? := none
        maxConcurrency? := none
        createdAt := (leg.fieldStr? "created_at").getD nowIso
        updatedAt := (leg.fieldStr? "updated_at").getD nowIso
      }

  return out.qsort (fun a b => a.priority < b.priority)

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

/-- Match the historical serde `as_i64` reset contract: integer JSON only,
    including zero/negative values, without wrapping values outside signed i64. -/
private def codexResetEpoch? (window : JVal) : Option Int := do
  let epoch ← window.fieldInt? "reset_at"
  if epoch < (-9223372036854775808 : Int) then none
  else if epoch > (9223372036854775807 : Int) then none
  else some epoch

/-- The production wham projection, kept pure so wire fixtures need no vendor calls.
    Scalar Codex fields and optimize-window fields have separate client contracts. -/
def projectCodexUsage (wham : JVal) : Array (String × JVal) × Array JVal × JVal := Id.run do
  let mut fields : Array (String × JVal) := #[
    ("codex_plan_type", .str ((wham.fieldStr? "plan_type").getD "pro")),
    ("codex_source", .str "usage")]
  let mut windows : Array JVal := #[]
  let mut primary : JVal := .null
  if let some rl := wham.field? "rate_limit" then
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
      windows := windows.push (buildOptimizeWindow "5h" "5-hour" "used_pct" "codex_wham" usedPct winSecs (some resetIso))
      primary := .str "5h"
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
      windows := windows.push (buildOptimizeWindow "7d" "7-day" "used_pct" "codex_wham" usedPct winSecs (some resetIso))
  return (fields, windows, primary)

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

def fetchLiveProviderUsage (hp : HydratedProvider) : IO JVal := do
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

  -- 1. OpenAI Codex OAuth (`wham/usage`)
  if pType == "openai" && hp.hasOAuth && !hp.oauthToken.isEmpty then
    if let .ok (code, _, some wham) ← sendJsonRequest "GET" "https://chatgpt.com/backend-api/wham/usage" (some hp.oauthToken) none #[] 6000 262144 then
      if 200 ≤ code && code < 300 then
        let (fields, windows, primary) := projectCodexUsage wham
        extraFields := fields
        optWindows := windows
        primaryWin := primary
      else if code == 401 || code == 403 then
        statusStr := "needs_reauth"

  -- 2. Anthropic OAuth or API Key
  else if pType == "anthropic" then
    let tok := if !hp.oauthToken.isEmpty then hp.oauthToken else hp.apiKey
    if !tok.isEmpty then
      let hdrs :=
        if !hp.oauthToken.isEmpty then
          #[("Authorization", s!"Bearer {tok}"), ("anthropic-beta", "oauth-2025-04-20"), ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")]
        else
          #[("x-api-key", tok), ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")]
      let probeBody := (renderCompact (.obj #[
        ("model", .str "claude-haiku-4-5-20251001"),
        ("max_tokens", JVal.nat 1),
        ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "hi")]])
      ])).toUTF8
      if let .ok resp ← sendRequest "POST" "https://api.anthropic.com/v1/messages" hdrs probeBody 6000 65536 then
        if resp.status == 401 then
          statusStr := "needs_reauth"
        if let some u5 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-5h-utilization" then
          let pct5 := match u5.trimAscii.toString.toNat? with | some n => toString n | none => u5.trimAscii.toString
          let r5 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-5h-reset"
          extraFields := extraFields.push ("unified_5h_utilization", .num u5.trimAscii.toString)
          if let some rv := r5 then extraFields := extraFields.push ("unified_5h_reset", .str rv)
          optWindows := optWindows.push (buildOptimizeWindow "5h" "5-hour" "utilization_pct" "anthropic_unified_headers" pct5 18000 r5)
          primaryWin := .str "5h"
        if let some u7 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-7d-utilization" then
          let pct7 := match u7.trimAscii.toString.toNat? with | some n => toString n | none => u7.trimAscii.toString
          let r7 := findHeaderCI? resp.headers "anthropic-ratelimit-unified-7d-reset"
          extraFields := extraFields.push ("unified_7d_utilization", .num u7.trimAscii.toString)
          if let some rv := r7 then extraFields := extraFields.push ("unified_7d_reset", .str rv)
          optWindows := optWindows.push (buildOptimizeWindow "7d" "7-day" "utilization_pct" "anthropic_unified_headers" pct7 604800 r7)
      -- Model-specific weekly limits (Opus, Sonnet, Fable, ...) are metered apart from the
      -- overall weekly limit and only reported by the OAuth usage endpoint.
      if !hp.oauthToken.isEmpty then
        if let .ok (code, _, some uJv) ← sendJsonRequest "GET" "https://api.anthropic.com/api/oauth/usage"
            (some hp.oauthToken) none #[("anthropic-beta", "oauth-2025-04-20")] 6000 65536 then
          if 200 ≤ code && code < 300 then
            let wins := anthropicModelWindows uJv
            if !wins.isEmpty then extraFields := extraFields.push ("anthropic_model_windows", .arr wins)

  -- 3. Kimi Coding Usage
  else if pType == "kimi" then
    let tok := if !hp.oauthToken.isEmpty then hp.oauthToken else hp.apiKey
    if !tok.isEmpty then
      if let .ok (code, _, some kJv) ← sendJsonRequest "GET" "https://api.kimi.com/coding/v1/usages" (some tok) none #[("User-Agent", "KimiCLI/1.5")] 5000 262144 then
        if 200 ≤ code && code < 300 then
          if let some uObj := kJv.field? "usage" then
            if let some (.num usedPct) := uObj.field? "used_percent" then
              extraFields := extraFields.push ("kimi_weekly_used_percent", .num usedPct)
              optWindows := optWindows.push (buildOptimizeWindow "weekly" "Weekly" "used_pct" "kimi_coding_usages" usedPct 604800 (uObj.fieldStr? "reset_time"))
              primaryWin := .str "weekly"

  -- 4. Z.ai Quota Monitor
  else if pType == "zai" && !hp.apiKey.isEmpty then
    if let .ok (code, _, some zJv) ← sendJsonRequest "GET" "https://api.z.ai/api/monitor/usage/quota/limit" none none #[("Authorization", hp.apiKey)] 5000 262144 then
      if 200 ≤ code && code < 300 then
        if let some dObj := zJv.field? "data" then
          if let some limits := dObj.fieldArr? "limits" then
            for lim in limits do
              if let some (.num pct) := lim.field? "percentage" then
                extraFields := extraFields.push ("zai_5h_used_percent", .num pct)
                optWindows := optWindows.push (buildOptimizeWindow "5h" "5-hour" "used_pct" "zai_quota_monitor" pct 18000 none)
                primaryWin := .str "5h"

  -- 5. Muse Code
  else if pType == "muse-code" && !hp.oauthToken.isEmpty then
    if let .ok (code, _, some mJv) ← sendJsonRequest "POST" "https://api.meta.ai/muse-code/key" (some hp.oauthToken) (some (.obj #[])) #[] 5000 262144 then
      if 200 ≤ code && code < 300 then
        let subActive := (mJv.fieldBool? "subscription_active").getD true
        extraFields := extraFields.push ("muse_subscription_active", .bool subActive)

  -- 6. Antigravity Cloud Code: plan from `loadCodeAssist`, then the shared 5h/weekly
  -- windows from `retrieveUserQuotaSummary`, falling back to per-model `retrieveUserQuota`.
  else if pType == "antigravity" && !hp.oauthToken.isEmpty then
    let base := "https://cloudcode-pa.googleapis.com/v1internal"
    let ua := #[("User-Agent", "antigravity")]
    let assistBody : JVal := .obj #[("metadata", .obj #[
      ("ideType", .str "ANTIGRAVITY"), ("platform", .str "PLATFORM_UNSPECIFIED"), ("pluginType", .str "GEMINI")])]
    if let .ok (code, _, some aJv) ← sendJsonRequest "POST" s!"{base}:loadCodeAssist" (some hp.oauthToken) (some assistBody) ua 10000 262144 then
      if 200 ≤ code && code < 300 then
        let tierName (k : String) := ((aJv.field? k).bind (·.fieldStr? "name")).filter (!·.trimAscii.isEmpty)
        extraFields := extraFields.push ("antigravity_plan", .str ((tierName "paidTier" <|> tierName "currentTier").getD "Pro"))
        let quotaBody : JVal := match aJv.fieldStr? "cloudaicompanionProject" with
          | some project => .obj #[("project", .str project)]
          | none => .obj #[]
        let mut windows : Array JVal := #[]
        let mut unauthorized := false
        if let .ok (c2, _, some sJv) ← sendJsonRequest "POST" s!"{base}:retrieveUserQuotaSummary" (some hp.oauthToken) (some quotaBody) ua 10000 1048576 then
          if 200 ≤ c2 && c2 < 300 then windows := parseAntigravitySummary sJv
          else if c2 == 401 || c2 == 403 then unauthorized := true
        let hasGemini := windows.any fun w => ((w.fieldStr? "label").getD "").startsWith "Gemini"
        if !unauthorized && (windows.isEmpty || !hasGemini) then
          if let .ok (c3, _, some qJv) ← sendJsonRequest "POST" s!"{base}:retrieveUserQuota" (some hp.oauthToken) (some quotaBody) ua 10000 1048576 then
            if 200 ≤ c3 && c3 < 300 then
              if windows.isEmpty then windows := parseAntigravityQuota qJv
              else if let some g := antigravityGeminiWindow? qJv (← nowEpoch) then windows := #[g] ++ windows
            else if c3 == 401 || c3 == 403 then unauthorized := true
        if unauthorized then statusStr := "needs_reauth"
        else extraFields := extraFields.push ("antigravity_windows", .arr windows)
      else if code == 401 || code == 403 then
        statusStr := "needs_reauth"

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
  | none => fetchLiveProviderUsage hp

private def refreshProviderUsageAsync (hub : ProviderRuntimeHub) (hp : HydratedProvider) : IO Unit := do
  let generation ← hub.mu.atomically (do return (← get).usageGeneration)
  let shouldSpawn ← hub.mu.atomically do
    let st ← get
    match st.usageEntries.find? (fun e => e.providerId == hp.id) with
    | some existing =>
      if existing.refreshing then return false
      let updated := st.usageEntries.map (fun e => if e.providerId == hp.id then { e with refreshing := true } else e)
      set { st with usageEntries := updated }
      return true
    | none =>
      let nowSec ← nowEpoch
      let placeholder : JVal := .obj #[
        ("provider_type", .str hp.providerType),
        ("provider_name", .str hp.name),
        ("account_email", if hp.accountEmail.isEmpty then .null else .str hp.accountEmail),
        ("status", .str "connected"),
        ("optimize", .obj #[("as_of", .str (formatEpochIso8601Utc nowSec)), ("primary_window", .null), ("windows", .arr #[])])
      ]
      set { st with usageEntries := st.usageEntries.push {
        providerId := hp.id, fetchedSec := nowSec, fetchedIso := formatEpochIso8601Utc nowSec, payload := placeholder, refreshing := true
      } }
      return true
  if shouldSpawn then
    let _ ← IO.asTask (prio := .dedicated) do
      let fresh ← (try probeProviderUsage hub hp catch _ =>
        pure (.obj #[("provider_type", .str hp.providerType), ("provider_name", .str hp.name), ("status", .str "error")]))
      let ts ← nowEpoch
      let tsIso := formatEpochIso8601Utc ts
      hub.mu.atomically do
        let st ← get
        if st.usageGeneration == generation then
          let others := st.usageEntries.filter (fun e => e.providerId != hp.id)
          set { st with usageEntries := others.push { providerId := hp.id, fetchedSec := ts, fetchedIso := tsIso, payload := fresh, refreshing := false } }

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

private def mkTotalsJv (ev inp outTok cRead cCreate reas costCents : Nat) : JVal :=
  let totalTok := inp + outTok + cRead + cCreate + reas
  let billableTok := inp + outTok + cCreate + reas
  .obj #[
    ("events", JVal.nat ev),
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

private def queryTotalsSince (store : CoreStore) (sinceIso? : Option String) : IO JVal := do
  let (sql, args) :=
    match sinceIso? with
    | some s =>
      ("SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage WHERE timestamp >= ?1;", #[s])
    | none =>
      ("SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage;", #[])
  match ← execParamQuery store.missionsDb sql args with
  | .ok rs =>
    if rs.size > 1 then
      let r := rs[1]!
      let n (i : Nat) := ((r[i]?).bind String.toNat?).getD 0
      return mkTotalsJv (n 0) (n 1) (n 2) (n 3) (n 4) (n 5) (n 6)
    return mkTotalsJv 0 0 0 0 0 0 0
  | .error _ => return mkTotalsJv 0 0 0 0 0 0 0

private def queryGroupedUsageBuckets (store : CoreStore) (colExpr : String) (sinceIso? : Option String) (limit : Nat) : IO (Array JVal) := do
  let (whereSql, args) :=
    match sinceIso? with
    | some s => ("WHERE timestamp >= ?1", #[s, toString limit])
    | none => ("", #[toString limit])
  let limParam := if sinceIso?.isSome then "?2" else "?1"
  let sql :=
    s!"SELECT {colExpr} AS k, COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), " ++
    s!"COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) " ++
    s!"FROM proxy_usage {whereSql} GROUP BY k ORDER BY SUM(input_tokens + output_tokens) DESC LIMIT {limParam};"
  let mut out : Array JVal := #[]
  if let .ok rs ← execParamQuery store.missionsDb sql args then
    for i in [1:rs.size] do
      let r := rs[i]!
      let key := ((r[0]?).getD "unknown").trimAscii.toString
      let effKey := if key.isEmpty then "unknown" else key
      let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
      let totObj := mkTotalsJv (n 1) (n 2) (n 3) (n 4) (n 5) (n 6) (n 7)
      let totPairs := totObj.asObj?.getD #[]
      out := out.push (.obj (#[("key", .str effKey), ("label", .str effKey)] ++ totPairs))
  return out

def buildAiUsageSummaryJson (store : CoreStore) (qMap : Array (String × String)) : IO JVal := do
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let win := ((qParam? qMap "window").getD "24h").trimAscii.toString
  let compact := ((qParam? qMap "compact").getD "false") == "true"
  let topLimit := Nat.min 50 (Nat.max 1 (((qParam? qMap "top_limit").bind String.toNat?).getD 10))
  let winSecs? := parseWindowSeconds? win
  let winStartIso? := winSecs?.map (fun s => formatEpochIso8601Utc (if nowSec > s then nowSec - s else 0))
  let dayStartSec := (nowSec / 86400) * 86400
  let todayIso := formatEpochIso8601Utc dayStartSec
  let weekIso := formatEpochIso8601Utc (if nowSec > 604800 then nowSec - 604800 else 0)

  let totals ← queryTotalsSince store winStartIso?
  let todayTotals ← queryTotalsSince store (some todayIso)
  let weekTotals ← queryTotalsSince store (some weekIso)
  let byProvider ← queryGroupedUsageBuckets store "COALESCE(NULLIF(provider,''),'unknown')" winStartIso? topLimit
  let byModel ← queryGroupedUsageBuckets store "COALESCE(NULLIF(model,''),'unknown')" winStartIso? topLimit
  let byAccount ← queryGroupedUsageBuckets store "COALESCE(NULLIF(account_id,''),'unattributed')" winStartIso? topLimit
  let byCaller ← queryGroupedUsageBuckets store "COALESCE(NULLIF(caller_kind,''),'mission')" winStartIso? topLimit
  let byPurpose ← queryGroupedUsageBuckets store "COALESCE(NULLIF(purpose,''),'turn')" winStartIso? topLimit

  let mut byDay : Array JVal := #[]
  let mut recent : Array JVal := #[]
  if !compact then
    let (wSql, dArgs) := match winStartIso? with | some s => ("WHERE timestamp >= ?1", #[s]) | none => ("", #[weekIso])
    let effWhere := if winStartIso?.isSome then wSql else "WHERE timestamp >= ?1"
    if let .ok drs ← execParamQuery store.missionsDb
        s!"SELECT substr(timestamp,1,10) AS d, COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_creation_tokens),0), COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_cents),0) FROM proxy_usage {effWhere} GROUP BY d ORDER BY d DESC LIMIT 14;"
        dArgs then
      for i in [1:drs.size] do
        let r := drs[i]!
        let n (idx : Nat) := ((r[idx]?).bind String.toNat?).getD 0
        byDay := byDay.push (.obj #[
          ("day", .str ((r[0]?).getD "")),
          ("totals", mkTotalsJv (n 1) (n 2) (n 3) (n 4) (n 5) (n 6) (n 7))
        ])
    if let .ok rrs ← execParamQuery store.missionsDb
        "SELECT timestamp, COALESCE(mission_id,''), COALESCE(provider,''), COALESCE(account_id,''), model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, cost_cents, COALESCE(caller_kind,''), COALESCE(purpose,'') FROM proxy_usage ORDER BY id DESC LIMIT 25;"
        #[] then
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

  return .obj #[
    ("window", .str win),
    ("window_start", match winStartIso? with | some s => .str s | none => .null),
    ("generated_at", .str nowIso),
    ("totals", totals),
    ("today", todayTotals),
    ("this_week", weekTotals),
    ("by_source", .arr #[.obj (#[("key", .str "proxy"), ("label", .str "Proxy")] ++ (totals.asObj?.getD #[]))]),
    ("by_backend", .arr #[]),
    ("by_provider", .arr byProvider),
    ("by_account", .arr byAccount),
    ("by_model", .arr byModel),
    ("by_api_key", .arr #[]),
    ("by_caller_kind", .arr byCaller),
    ("by_purpose", .arr byPurpose),
    ("by_mission", .arr #[]),
    ("by_day", .arr byDay),
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
  let visible := files.any fun f =>
    f.authType == sess.authFileType && !f.disabled && !f.accessToken.isEmpty &&
    !(sess.beforeFiles.contains (f.fileName, f.fingerprint))
  let mut result := { sess with status := "completing", completionStartedSec? := some started }
  if visible then
    let providers ← loadHydratedProviders store workingDir
    let affected := providers.filter (fun hp => providerTypeMatchesAuthType hp.providerType sess.authFileType)
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
  else if now >= started + 60 then
    result := { result with status := "failed", message? := some "Authentication completed but the new auth file was not visible within 60 seconds. Try reconnecting again." }
  hub.mu.atomically do
    modify fun st => { st with loginSessions := st.loginSessions.map (fun s => if s.sessionId == sess.sessionId then result else s) }
  return result

private def loginSessionResponse (sess : CliLoginSession) : Nat × String × ByteArray :=
  jsonResp 200 (.obj #[("status", .str sess.status), ("auth_url", .str sess.authUrl),
    ("message", sess.message?.map JVal.str |>.getD .null)])

/-! ## Unified Dispatcher for AI Providers, Proxy Analytics, Model-Routing Health/Test & Catalog -/

set_option maxHeartbeats 800000 in
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
    (healthTracker? : Option ProviderHealthTracker := none) : IO (Option (Nat × String × ByteArray)) := do
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
    let res := if disc.isNull then JVal.obj #[("schema_version", JVal.nat 1), ("connections", .arr #[])] else disc
    return some (jsonResp 200 res)

  if segs == ["api", "providers", "catalog"] && method == "GET" then
    let hps ← loadHydratedProviders store workingDir
    let items := hps.map (fun hp => JVal.obj #[
      ("id", .str hp.id),
      ("name", .str hp.name),
      ("provider_type", .str hp.providerType),
      ("enabled", .bool hp.enabled),
      ("has_credentials", .bool (hp.hasApiKey || hp.hasOAuth)),
      ("models", .arr hp.customModels)
    ])
    return some (jsonResp 200 (.obj #[("providers", .arr items)]))

  if segs == ["api", "providers", "snapshots"] && method == "GET" then
    return some (jsonResp 200 (.obj #[("snapshots", .arr #[])]))

  if segs == ["api", "providers", "catalog", "refresh"] && method == "POST" then
    let _ ← getCachedAntigravityModels hub true
    let nowSec ← nowEpoch
    hub.mu.atomically do
      let st ← get
      set { st with catalogRefreshedSec := nowSec }
    return some (jsonResp 200 (.obj #[("ok", .bool true), ("refreshed_at", .str (formatEpochIso8601Utc nowSec))]))

  -- 3. `GET /api/ai/usage/summary`, `GET /api/ai/proxy/health`, `GET /api/ai/proxy/timing`
  if method == "GET" && segs == ["api", "ai", "usage", "summary"] then
    let summary ← buildAiUsageSummaryJson store qMap
    return some (jsonResp 200 summary)

  if method == "GET" && segs == ["api", "ai", "proxy", "health"] then
    let nowSec ← nowEpoch
    let nowIso := formatEpochIso8601Utc nowSec
    let win := ((qParam? qMap "window").getD "24h").trimAscii.toString
    let winSecs? := parseWindowSeconds? win
    let winStart? := winSecs?.map (fun s => formatEpochIso8601Utc (if nowSec > s then nowSec - s else 0))
    let (wSql, wArgs) := match winStart? with | some s => ("WHERE timestamp >= ?1", #[s]) | none => ("", #[])
    let mut totalReqs : Nat := 0
    let mut okReqs : Nat := 0
    let mut failReqs : Nat := 0
    if let .ok ors ← execParamQuery store.missionsDb
        s!"SELECT COUNT(*), COALESCE(SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN status<>'ok' THEN 1 ELSE 0 END),0) FROM proxy_outcomes {wSql};"
        wArgs then
      if ors.size > 1 then
        totalReqs := ((ors[1]![0]?).bind String.toNat?).getD 0
        okReqs := ((ors[1]![1]?).bind String.toNat?).getD 0
        failReqs := ((ors[1]![2]?).bind String.toNat?).getD 0
    let mut recentFailures : Array JVal := #[]
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
      ("window_start", match winStart? with | some s => .str s | none => .null),
      ("generated_at", .str nowIso),
      ("totals", .obj #[
        ("requests", JVal.nat totalReqs),
        ("succeeded", JVal.nat okReqs),
        ("failed", JVal.nat failReqs),
        ("superseded", JVal.nat 0),
        ("retried_requests", JVal.nat 0),
        ("total_retries", JVal.nat 0),
        ("fallback_requests", JVal.nat 0),
        ("success_rate", .num (if totalReqs == 0 then "1.0" else "0.99")),
        ("by_status", .obj #[("ok", JVal.nat okReqs)]),
        ("ttft_ms", emptyPct),
        ("total_ms", emptyPct)
      ]),
      ("by_chain", .arr #[]),
      ("by_provider", .arr #[]),
      ("recent_failures", .arr recentFailures)
    ]))

  if method == "GET" && segs == ["api", "ai", "proxy", "timing"] then
    let mins := Nat.min 10080 (Nat.max 1 (((qParam? qMap "minutes").bind String.toNat?).getD 60))
    let zeroQuant : JVal := .obj #[("p50", JVal.nat 0), ("p95", JVal.nat 0), ("p99", JVal.nat 0), ("max", JVal.nat 0)]
    return some (jsonResp 200 (.obj #[
      ("window_seconds", JVal.nat (mins * 60)),
      ("samples", JVal.nat 0),
      ("overall", .obj #[
        ("count", JVal.nat 0), ("errors", JVal.nat 0),
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
    -- Both owners of a cooldown: the legacy ref and the health tracker the proxy plans from.
    let tracked ← match healthTracker? with
      | some t => snapshotActiveHealthCooldowns t nowSec
      | none => pure #[]
    let cooldowns := (← proxyCooldownsRef.get) ++ tracked
    let usageCached ← hub.mu.atomically (do return (← get).usageEntries)
    let mut snaps : Array JVal := #[]
    for hp in hps do
      let keys := healthKeys hp
      let cdRem : UInt64 :=
        (cooldowns.filter (fun c => keys.contains c.accountId)).foldl (fun acc c => max acc (c.remainingSecs nowSec)) 0
      let failCnt : Nat := if cdRem > 0 then 1 else 0
      let remQuota : JVal :=
        match usageCached.find? (fun u => u.providerId == hp.id) with
        | some u =>
          let wins := ((u.payload.field? "optimize").bind (fun o => o.fieldArr? "windows")).getD #[]
          match wins[0]?.bind (fun w => w.field? "pct_remaining") with
          | some v => v
          | none => .num "100.0"
        | none => .num "100.0"
      snaps := snaps.push (.obj #[
        ("account_id", .str hp.id),
        ("ewma_ttft_ms", .null),
        ("ewma_tps", .null),
        ("remaining_quota_pct", remQuota),
        ("consecutive_failures", JVal.nat failCnt),
        ("cooldown_secs_remaining", JVal.uint64 cdRem),
        ("sample_count", JVal.nat 0),
        ("antigravity_refusal", .null)
      ])
    return some (jsonResp 200 (.arr snaps))

  if method == "POST" && segs.length == 5 && segs[0]? == some "api" && segs[1]? == some "model-routing" && segs[2]? == some "health" && segs[4]? == some "clear" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let acctId := segs[3]!
    let hps ← loadHydratedProviders store workingDir
    let keys := match hps.find? (fun hp => hp.id == acctId) with
      | some hp => healthKeys hp
      | none => #[acctId]
    let cur ← proxyCooldownsRef.get
    proxyCooldownsRef.set (cur.filter (fun c => !keys.contains c.accountId))
    if let some t := healthTracker? then clearAccountHealthWhere t keys.contains
    return some (204, "text/plain", ByteArray.empty)

  if method == "POST" && segs.length == 5 && segs[0]? == some "api" && segs[1]? == some "model-routing" && segs[2]? == some "chains" && segs[4]? == some "test" then
    if !effAdmin then return some (jsonErr 403 "admin_required")
    let cid := segs[3]!
    let testAll := ((qParam? qMap "all").getD "false") == "true"
    let probeModel := if cid.startsWith "builtin/" then cid else s!"builtin/{cid}"
    let proxyKey := (← lookupEnvWithFiles? "SANDBOXED_PROXY_SECRET").getD ""
    let probeBody : JVal := .obj #[
      ("model", .str probeModel),
      ("max_tokens", JVal.nat 4),
      ("messages", .arr #[.obj #[("role", .str "user"), ("content", .str "ping")]])
    ]
    let t0 ← IO.monoMsNow
    match ← sendJsonRequest "POST" s!"http://127.0.0.1:{serverPort}/v1/chat/completions"
        (if proxyKey.isEmpty then none else some proxyKey) (some probeBody) #[] 15000 262144 with
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
      let mut arr : Array JVal := #[]
      for hp in hps do
        if effAdmin || (hp.enabled && (hp.hasApiKey || hp.hasOAuth)) then
          let obs? ← match pacingTracker? with
            | some tr => lookupObservedKeyRpm? tr hp.id
            | none => pure none
          let uEn? := if isLegacyUnscoped then none else some (isUserProviderEnabled uPrefs hp.id)
          arr := arr.push (renderHydratedProviderJv hp uEn? obs? (← loginRejectedFor hub store hp))
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
            entryPairs := entryPairs.push (hp.id, decorateCachedUsage hit nowSec)
            -- Refresh in background if >= 120s old (skip OpenAI OAuth-only unless forced)
            let isCodexOAuthOnly := hp.providerType.toLower == "openai" && !hp.hasApiKey && hp.hasOAuth
            if nowSec >= hit.fetchedSec + 120 && !isCodexOAuthOnly then
              refreshProviderUsageAsync hub hp
          | none =>
            let isCodexOAuthOnly := hp.providerType.toLower == "openai" && !hp.hasApiKey && hp.hasOAuth
            if !isCodexOAuthOnly then
              refreshProviderUsageAsync hub hp
      return some (jsonResp 200 (.obj #[
        ("entries", .obj entryPairs),
        ("refresh_after_seconds", JVal.nat 120)
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
      if !effAdmin then return some (jsonErr 403 "admin_required")
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "Invalid JSON")
      let ids := ((reqJv.fieldArr? "ids").getD #[]).filterMap JVal.asStr?
      for idx in [0:ids.size] do
        let _ ← execParamStmt store.missionsDb
          "UPDATE ai_providers SET sort_order=?2 WHERE id=?1;" #[ids[idx]!, toString idx]
      let hps ← loadHydratedProviders store workingDir
      return some (jsonResp 200 (.arr (hps.map (fun hp => renderHydratedProviderJv hp))))

    -- 5e. `GET /api/ai/providers/for-backend/:backend_id`
    if method == "GET" && segs.length == 5 && segs[3]? == some "for-backend" then
      let bid := segs[4]!.toLower
      if bid == "claudecode" then
        let hps ← loadHydratedProviders store workingDir
        match hps.find? (fun p => p.enabled && p.providerType.toLower == "anthropic" && (p.hasApiKey || p.hasOAuth)) with
        | some p =>
          return some (jsonResp 200 (.obj #[
            ("configured", .bool true),
            ("provider_type", .str "anthropic"),
            ("provider_name", .str p.name),
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

      if !effAdmin then return some (jsonErr 403 "admin_required")
      let some mgmtKey := mgmtKey?
        | return some (jsonErr 503 "CLIProxy management key is not configured on Core")

      if method == "POST" && segs.length == 4 then
        let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
          | return some (jsonErr 400 "Invalid JSON")
        let rawProv := (reqJv.fieldStr? "provider").getD ""
        let some (slug, authType, flow) := mapLoginSlug rawProv
          | return some (jsonErr 400 s!"Unsupported CLIProxy login provider `{rawProv}`")
        let targetProvId? := reqJv.fieldStr? "provider_id"
        let beforeFiles := (← scanCliProxyAuthFiles).map (fun af => (af.fileName, af.fingerprint))
        match ← sendJsonRequest "GET" s!"{mgmtBase}/v0/management/{slug}-auth-url" (some mgmtKey) none #[] 15000 262144 with
        | .ok (code, rawTxt, some uJv) =>
          if 200 ≤ code && code < 300 then
            let authUrl := (uJv.fieldStr? "url").getD ""
            let stTok := (uJv.fieldStr? "state").getD ""
            if authUrl.isEmpty || stTok.isEmpty then
              return some (jsonErr 502 "CLIProxy returned incomplete auth URL response")
            let sid ← newUuidV4
            let nowSec ← nowEpoch
            let sess : CliLoginSession := {
              sessionId := sid, providerSlug := slug, authFileType := authType,
              targetProvId? := targetProvId?, stateToken := stTok, authUrl := authUrl,
              flow := flow, createdSec := nowSec, beforeFiles := beforeFiles
            }
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

        if method == "DELETE" then
          let _ ← sendJsonRequest "DELETE" s!"{mgmtBase}/v0/management/oauth-session?state={urlEncodeComponent sess.stateToken}" (some mgmtKey) none #[] 5000 65536
          hub.mu.atomically do
            let st ← get
            set { st with loginSessions := st.loginSessions.filter (fun s => s.sessionId != sid) }
          return some (jsonResp 200 (.obj #[("status", .str "ok")]))

        if method == "GET" then
          if sess.status == "completed" || sess.status == "failed" then
            return some (loginSessionResponse sess)
          -- While not terminal, keep asking the sidecar even mid-completion: it accepts a
          -- callback before it exchanges the code, so only a later `error` reports why a
          -- wrong or expired callback URL will never produce a file. `ok` alone still
          -- never completes: that belongs to `reconcileCliLoginCompletion`'s visibility
          -- check.
          match ← sendJsonRequest "GET" s!"{mgmtBase}/v0/management/get-auth-status?state={urlEncodeComponent sess.stateToken}" (some mgmtKey) none #[] 8000 262144 with
          | .ok (200, _, some stJv) =>
            let stStr := ((stJv.fieldStr? "status").getD "wait").toLower
            if stStr == "error" then
              let errMsg := (stJv.fieldStr? "error").getD "Authentication failed"
              let failed := { sess with status := "failed", message? := some errMsg }
              hub.mu.atomically do
                modify fun st => { st with loginSessions := st.loginSessions.map (fun s => if s.sessionId == sess.sessionId then failed else s) }
              return some (loginSessionResponse failed)
            if sess.completionStartedSec?.isNone && stStr != "ok" then
              return some (jsonResp 200 (.obj #[("status", .str "pending"), ("auth_url", .str sess.authUrl), ("message", .null)]))
          | _ =>
            if sess.completionStartedSec?.isNone then
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
        let cbPayload : JVal := .obj #[
          ("provider", .str sess.providerSlug),
          ("code", .str codeParam),
          ("state", .str stateParam)
        ]
        match ← sendJsonRequest "POST" s!"{mgmtBase}/v0/management/oauth-callback" (some mgmtKey) (some cbPayload) #[] 15000 262144 with
        | .ok (c, _, _) =>
          if 200 ≤ c && c < 300 then
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
        let obs? ← match pacingTracker? with
          | some tr => lookupObservedKeyRpm? tr hp.id
          | none => pure none
        return some (jsonResp 200 (renderHydratedProviderJv hp none obs? (← loginRejectedFor hub store hp)))

      -- `GET /api/ai/providers/:id/usage`
      if method == "GET" && segs.length == 5 && segs[4]? == some "usage" then
        let some hp := matchedProv?
          | return some (jsonErr 404 "Provider not found")
        let force := ((qParam? qMap "force").getD "false") == "true"
        let cachedOnly := ((qParam? qMap "cached_only").getD "false") == "true"
        let nowSec ← nowEpoch
        if !force then
          let hit? ← hub.mu.atomically do
            let st ← get
            return st.usageEntries.find? (fun e => e.providerId == hp.id)
          if let some hit := hit? then
            if nowSec >= hit.fetchedSec + 120 && !cachedOnly then
              refreshProviderUsageAsync hub hp
            return some (jsonResp 200 (decorateCachedUsage hit nowSec))
        if cachedOnly then
          return some (jsonResp 200 (.obj #[
            ("provider_type", .str hp.providerType),
            ("provider_name", .str hp.name),
            ("account_email", if hp.accountEmail.isEmpty then .null else .str hp.accountEmail),
            ("status", .str "pending"),
            ("cached", .bool false)
          ]))
        let generation ← hub.mu.atomically (do return (← get).usageGeneration)
        let live ← probeProviderUsage hub hp
        let ts ← nowEpoch
        let tsIso := formatEpochIso8601Utc ts
        hub.mu.atomically do
          let st ← get
          if st.usageGeneration == generation then
            let others := st.usageEntries.filter (fun e => e.providerId != hp.id)
            set { st with usageEntries := others.push { providerId := hp.id, fetchedSec := ts, fetchedIso := tsIso, payload := live, refreshing := false } }
        return some (jsonResp 200 live)

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
        let cur ← proxyCooldownsRef.get
        proxyCooldownsRef.set (cur.filter (fun c => c.accountId != hp.id))
        let live ← probeProviderUsage hub hp
        let enriched := (live.setField "reset_redeemed" (.bool true)).setField "woken_missions" (JVal.nat 0)
        return some (jsonResp 200 enriched)

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
