/-
  OrbCore.CloudHttpAndWorker:
  Production Cloud Agent HTTP Surface & Background Execution Worker (`0 import Lean`, `0 sorryAx`).
  Covers:
  - `GET /api/cloud/accounts` (`grok-default`, `cursor-default`, `paloma` with single-tenant `*_OWNER=prod|dev|admin` parity)
  - `GET /api/cloud/usage`
  - `GET /api/cloud/hermes/options`
  - `GET|PUT /api/cloud/hermes/settings` (`/var/lib/{runtime}/config.yaml`, `SOUL.md`, env files, `state.db`, `systemctl`)
  - `GET /api/cloud/cursor/options`
  - `GET /api/control/missions/:id/cloud`
  - `GET /api/control/missions/:id/cloud/events`
  - `GET /api/control/missions/:id/cloud/artifact`
  - `GET /api/control/missions/:id/cloud/children`
  - `POST /api/control/missions/:id/cloud/approval`
  - `POST /api/control/missions/:id/cloud/cancel`
  - `handleCloudMissionCreate` (`POST /api/control/missions` with `"cloud"` selection)
  - `handleCloudFollowUp` (`POST /api/control/message` for cloud missions)
  - `ensureCloudMissionWorker` & `startCloudSupervisorLoop` (Hermes `/v1/runs`, Cursor Cloud `/v1/agents`, Grok Bot)
-/
import Std.Sync.Mutex
import LeanSys.Auth
import LeanSys.Http
import OrbNetLeaf.Crypto
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.Sqlite
import OrbBin.HttpClient
import OrbCore.Store
import OrbCore.QueueCont
import OrbCore.CloudAgents
import OrbCore.R7Core
import OrbCore.LegacyHydrate

namespace OrbCore.CloudHttpAndWorker

open LeanSys.Auth
open LeanSys.Http
open OrbNetLeaf.Crypto
open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.Sqlite
open OrbBin.HttpClient
open OrbCore.Store
open OrbCore.QueueCont
open OrbCore.CloudAgents
open OrbCore.R7Core
open OrbCore.LegacyHydrate

/-! ## Runtime Cache & Worker Coordination Hub -/

structure CloudCachedEntry where
  key      : String
  savedSec : UInt64
  payload  : JVal
  deriving Repr, Inhabited

structure CloudHubState where
  accountsCache  : Array CloudCachedEntry := #[]
  usageCache     : Array CloudCachedEntry := #[]
  cursorRepoCache : Array CloudCachedEntry := #[]
  activeWorkers  : Array String := #[]

structure CloudRuntimeHub where
  mu : Std.Mutex CloudHubState

def newCloudRuntimeHub : IO CloudRuntimeHub := do
  let mu ← Std.Mutex.new ({} : CloudHubState)
  return { mu }

private def getCachedJson? (entries : Array CloudCachedEntry) (key : String) (nowSec ttlSec : UInt64) : Option JVal :=
  match entries.find? (fun e => e.key == key) with
  | some e => if nowSec ≤ e.savedSec + ttlSec then some e.payload else none
  | none => none

private def putCachedJson (entries : Array CloudCachedEntry) (key : String) (nowSec : UInt64) (payload : JVal) : Array CloudCachedEntry :=
  let kept := (entries.filter (fun e => e.key != key && nowSec ≤ e.savedSec + 3600))
  let trimmed := if kept.size >= 64 then kept.extract (kept.size - 63) kept.size else kept
  trimmed.push { key, savedSec := nowSec, payload }

private def tryClaimCloudWorker (hub : CloudRuntimeHub) (missionId : String) : IO Bool :=
  hub.mu.atomically do
    let st ← get
    if st.activeWorkers.contains missionId then
      return false
    set { st with activeWorkers := st.activeWorkers.push missionId }
    return true

private def releaseCloudWorker (hub : CloudRuntimeHub) (missionId : String) : IO Unit :=
  hub.mu.atomically do
    let st ← get
    set { st with activeWorkers := st.activeWorkers.filter (· != missionId) }

/-! ## HTTP Response, Query & Env File Helpers -/

private def execParamStmt (db : SqliteDb) (sql : String) (params : Array String) : IO (Except String Unit) := do
  match ← execParamQuery db sql params with
  | .ok _ => return .ok ()
  | .error e => return .error e

private def hasMultipleActiveUsers (st : CoreStore) : IO Bool := do
  match ← execParamQuery st.missionsDb "SELECT COUNT(*) FROM users WHERE disabled=0;" #[] with
  | .ok rows => return (((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 1
  | .error _ => return false

private def canAccessMission
    (st : CoreStore)
    (missionId callerUserId bootstrapAdminId : String)
    (isLegacyUnscoped requireOwner : Bool) : IO Bool := do
  if isLegacyUnscoped then return true
  let (exists_, isOwner, isPart) ← getMissionRelationship st missionId callerUserId
  if !exists_ then
    return false
  if isOwner then return true
  if !bootstrapAdminId.isEmpty && callerUserId == bootstrapAdminId then
    let multi ← hasMultipleActiveUsers st
    if !multi then return true
  if requireOwner then return false
  return isPart

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

private def parseEnvFileContent (raw : String) : Array (String × String) := Id.run do
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
        if !key.isEmpty then
          out := out.push (key, val)
  return out

private def readEnvFilePairs (path : String) : IO (Array (String × String)) := do
  let fp := System.FilePath.mk path
  if !(← fp.pathExists) then return #[]
  match ← (try some <$> IO.FS.readFile fp catch _ => pure none) with
  | some raw => return parseEnvFileContent raw
  | none => return #[]

private def lookupEnvFileKey? (paths : Array String) (key : String) : IO (Option String) := do
  if let some v ← IO.getEnv key then
    let tv := v.trimAscii.toString
    if !tv.isEmpty then return some tv
  for p in paths do
    let pairs ← readEnvFilePairs p
    if let some (_, v) := pairs.find? (fun (k, _) => k == key) then
      let tv := v.trimAscii.toString
      if !tv.isEmpty then return some tv
  return none

private def getEnvTrimmed (key : String) : IO String := do
  let cloudEnvFiles := #["/etc/sandboxed-sh/cloud-agents-prod.env", "/etc/sandboxed-sh/cloud-agents-dev.env", "/etc/open_agent/open_agent.env"]
  match ← IO.getEnv key with
  | some v =>
    let tv := v.trimAscii.toString
    if !tv.isEmpty then return tv
    return (← lookupEnvFileKey? cloudEnvFiles key).getD ""
  | none =>
    return (← lookupEnvFileKey? cloudEnvFiles key).getD ""

private def runShortCmd (prog : String) (args : Array String) : IO (Nat × String) := do
  let env ← environList
  let sp ← spawnPgrp prog args env false false true
  if sp.pid < 0 then
    return (127, "")
  let mut acc := ByteArray.empty
  if sp.stdoutFd >= 0 then
    let mut eof := false
    while !eof && acc.size < 262144 do
      let chunk ← readFdChunk sp.stdoutFd 8192
      if chunk.isEmpty then eof := true else acc := acc ++ chunk
    closeFdRaw sp.stdoutFd
  let st ← waitpidBlock sp.pid
  let exitCode := ((st >>> 8) &&& 0xFF).toNat
  return (exitCode, (String.fromUTF8? acc).getD "")

/-! ## Single-Tenant + Multi-User Owner Matching & Hermes Runtime Discovery -/

/-- Match cloud owner env var (`HERMES_CLOUD_OWNER`, `CURSOR_CLOUD_OWNER`, `GROK_BOT_OWNER`)
    against `callerUserId`, `callerUsername`, or operator `"prod"|"dev"|"admin"|"default"|"local"`
    aliases (which bind uniquely to `bootstrapAdminId` in multi-user mode and never match members). -/
def matchesCloudOwner
    (store : CoreStore)
    (ownerVal callerUserId callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool) : IO Bool := do
  let ov := ownerVal.trimAscii.toString
  if ov.isEmpty then return false
  if !callerUserId.isEmpty && ov == callerUserId then return true
  let ovl := ov.toLower
  let isEnvAlias := ovl == "prod" || ovl == "dev" || ovl == "admin" || ovl == "default" || ovl == "local"
  if !isEnvAlias && !callerUsername.isEmpty && ovl == callerUsername.toLower then return true
  if isEnvAlias && (isAdmin || isLegacyUnscoped) && !bootstrapAdminId.isEmpty && callerUserId == bootstrapAdminId then
    return true
  let multi ← hasMultipleActiveUsers store
  if !multi && isEnvAlias && (isLegacyUnscoped || isAdmin) then
    return true
  return false

private def stripTrailingSlash (s : String) : String :=
  if s.endsWith "/" then (s.dropEnd 1).toString else s

def assistantRuntimeName (serverPort : UInt16) : IO String := do
  let sbEnv := (← getEnvTrimmed "SANDBOXED_ENV").toLower
  let oaEnv := (← getEnvTrimmed "OPEN_AGENT_ENV").toLower
  if serverPort == 3002 || sbEnv == "dev" || oaEnv == "dev" then
    return "hermes-assistant-dev"
  return "hermes-assistant"

def assistantHomeDir (runtimeName : String) : IO String := do
  let override := (← getEnvTrimmed "HERMES_HOME").trimAscii.toString
  if !override.isEmpty then
    return stripTrailingSlash override
  return s!"/var/lib/{runtimeName}"

def assistantLoopbackUrl (runtimeName : String) : IO String := do
  let override := (← getEnvTrimmed "HERMES_API_URL").trimAscii.toString
  if !override.isEmpty then
    return stripTrailingSlash override
  if runtimeName == "hermes-assistant-dev" then return "http://127.0.0.1:8643"
  return "http://127.0.0.1:8642"

def assistantEnvPaths (runtimeName : String) : IO (Array String) := do
  let homeOverride := (← getEnvTrimmed "HERMES_HOME").trimAscii.toString
  let mut paths : Array String := #[]
  if !homeOverride.isEmpty then
    paths := paths.push s!"{stripTrailingSlash homeOverride}/.env"
  paths := paths.push s!"/etc/sandboxed-sh/{runtimeName}.env"
  paths := paths.push s!"/var/lib/{runtimeName}/.env"
  return paths

def resolveHermesServerKeyForRuntime? (runtimeName : String) : IO (Option String) := do
  let paths ← assistantEnvPaths runtimeName
  if let some v ← lookupEnvFileKey? paths "API_SERVER_KEY" then
    if !v.isEmpty then return some v
  return none

def resolveHermesServerKey? (runtimeName : String) : IO (Option String) := do
  if let some v ← resolveHermesServerKeyForRuntime? runtimeName then
    return some v
  if runtimeName != "hermes-assistant" then
    if let some v ← lookupEnvFileKey? #["/etc/sandboxed-sh/hermes-assistant.env", "/var/lib/hermes-assistant/.env"] "API_SERVER_KEY" then
      if !v.isEmpty then return some v
  return none

/-- Verify a `/v1/capabilities` JSON object for Hermes run-replay readiness.
    When `features` is present, rejects gateways that explicitly disable
    `features.runs_idempotency.durable` or `features.run_events_replay`. -/
def checkHermesCapabilitiesReady (capsJv : JVal) : Except String Unit :=
  match capsJv with
  | .obj _ =>
    match capsJv.field? "features" with
    | some (.obj _) =>
      let replayOk :=
        match (capsJv.field? "features").bind (·.fieldBool? "run_events_replay") with
        | some false => false
        | _ => true
      let durableOk :=
        match (capsJv.field? "features").bind (·.field? "runs_idempotency") with
        | some (.obj _) =>
          match ((capsJv.field? "features").bind (·.field? "runs_idempotency")).bind (·.fieldBool? "durable") with
          | some false => false
          | _ => true
        | some (.bool false) => false
        | _ => true
      if replayOk && durableOk then
        .ok ()
      else
        .error "Hermes gateway is missing durable run replay capabilities; upgrade hermes-gateway"
    | _ => .ok ()
  | _ => .error "Invalid Hermes capabilities response"

private def probeHermesCapabilitiesAt (baseUrl apiKey : String) (timeoutMs : UInt32 := 1500) : IO (Except String JVal) := do
  match ← sendJsonRequest "GET" s!"{baseUrl}/v1/capabilities" (some apiKey) none #[] timeoutMs 262144 with
  | .ok (code, _, some jv) =>
    if 200 ≤ code && code < 300 then
      match checkHermesCapabilitiesReady jv with
      | .ok () => return .ok jv
      | .error reason => return .error reason
    else
      return .error "Hermes is not responding; other cloud services remain available"
  | _ =>
    return .error "Hermes is not responding; other cloud services remain available"

private def resolveEffectiveHermesEndpoint (serverPort : UInt16) : IO (String × String × Option String × Option JVal × Option String) := do
  let rtName ← assistantRuntimeName serverPort
  let urlOverride := (← getEnvTrimmed "HERMES_API_URL").trimAscii.toString
  let url0 ← assistantLoopbackUrl rtName
  let key0? ← resolveHermesServerKey? rtName
  let some k0 := key0?
    | return (rtName, url0, none, none, some "Hermes API server key is not configured; enable Hermes remote access first")
  match ← probeHermesCapabilitiesAt url0 k0 1500 with
  | .ok capsJv => return (rtName, url0, some k0, some capsJv, none)
  | .error primaryErr =>
    -- Fallback probe to production port 8642 only if dev runtime isn't separate and no explicit HERMES_API_URL override is set
    if rtName == "hermes-assistant-dev" && urlOverride.isEmpty then
      let prodKey := (← resolveHermesServerKeyForRuntime? "hermes-assistant").getD k0
      match ← probeHermesCapabilitiesAt "http://127.0.0.1:8642" prodKey 1500 with
      | .ok capsJv2 => return ("hermes-assistant", "http://127.0.0.1:8642", some prodKey, some capsJv2, none)
      | .error fallbackErr => return (rtName, url0, some k0, none, some fallbackErr)
    return (rtName, url0, some k0, none, some primaryErr)

private def checkGrokBotCredentialValid (credPath : String) (nowSec : UInt64) : IO Bool := do
  let p := credPath.trimAscii.toString
  if p.isEmpty then return false
  let fp := System.FilePath.mk p
  if !(← fp.pathExists) then return false
  let some raw ← (try some <$> IO.FS.readFile fp catch _ => pure none)
    | return false
  let .ok jv := OrbBin.Json.parse raw
    | return false
  let tok := ((jv.fieldStr? "access_token").getD "").trimAscii.toString
  if tok.isEmpty then return false
  match tok.splitOn "." with
  | [_, payloadB64, _] =>
    let norm := String.ofList (payloadB64.toList.map (fun c => if c == '-' then '+' else if c == '_' then '/' else c))
    let padLen := (4 - (norm.length % 4)) % 4
    let padded := norm ++ String.ofList (List.replicate padLen '=')
    match base64Decode? padded with
    | some bytes =>
      match OrbBin.Json.parseBytes bytes with
      | .ok claims =>
        match claims.fieldUInt64? "exp" with
        | some exp => return exp > nowSec
        | none => return true
      | .error _ => return true
    | none => return true
  | _ => return true

/-! ## `GET /api/cloud/accounts` & `GET /api/cloud/usage` -/

def buildCloudAccountsJson
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (serverPort : UInt16)
    (callerUserId callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool) : IO JVal := do
  let nowSec ← nowEpoch
  let cacheKey := s!"{serverPort}:{callerUserId}:{callerUsername}:{isAdmin}:{isLegacyUnscoped}"
  let cached? ← hub.mu.atomically do
    let st ← get
    return getCachedJson? st.accountsCache cacheKey nowSec 15
  if let some hit := cached? then
    return hit

  -- 1. Grok Bot (`grok-default`)
  let grokOwner ← getEnvTrimmed "GROK_BOT_OWNER"
  let grokValidated := (← getEnvTrimmed "GROK_BOT_VALIDATED") == "1"
  let grokOwnerOk ← matchesCloudOwner store grokOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  let grokAllowed := grokOwnerOk && grokValidated
  let grokCredFile ← getEnvTrimmed "GROK_BOT_CREDENTIAL_FILE"
  let grokConnected ← if grokAllowed then checkGrokBotCredentialValid grokCredFile nowSec else pure false
  let grokAvail := grokAllowed && grokConnected
  let grokReason : JVal :=
    if grokAllowed && !grokConnected then
      .str "Grok Bot credential is missing or expired: re-export the desktop session"
    else if grokAvail then
      .null
    else
      .str "Experimental connector. Bots on this account share one computer"
  let grokObj : JVal := .obj #[
    ("id", .str "grok-default"),
    ("provider", .str "grok_bot"),
    ("label", .str "Grok Bot"),
    ("available", .bool grokAvail),
    ("experimental", .bool true),
    ("reason", grokReason),
    ("capabilities", .obj #[
      ("models", .bool false),
      ("attachments", .bool false),
      ("repository", .bool false),
      ("follow_up", .bool true),
      ("cancel", .bool true),
      ("detailed_events", .bool false),
      ("artifacts", .bool false)
    ])
  ]

  -- 2. Cursor Cloud (`cursor-default`)
  let cursorOwner ← getEnvTrimmed "CURSOR_CLOUD_OWNER"
  let cursorOwnerOk ← matchesCloudOwner store cursorOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  let cursorKey ← getEnvTrimmed "CURSOR_CLOUD_API_KEY"
  let cursorConnected := cursorOwnerOk && !cursorKey.isEmpty
  let cursorEnabled := cursorOwnerOk && (← getEnvTrimmed "CURSOR_CLOUD_VALIDATED") == "1"
  let cursorAvail := cursorConnected && cursorEnabled
  let cursorReason : JVal :=
    if !cursorConnected then .str "Connect a user API key on Core"
    else if !cursorEnabled then .str "A bounded cloud canary must pass before activation"
    else .null
  let cursorObj : JVal := .obj #[
    ("id", .str "cursor-default"),
    ("provider", .str "cursor_cloud"),
    ("label", .str "Cursor Cloud"),
    ("available", .bool cursorAvail),
    ("experimental", .bool false),
    ("reason", cursorReason),
    ("capabilities", .obj #[
      ("models", .bool true),
      ("attachments", .bool false),
      ("repository", .bool true),
      ("follow_up", .bool true),
      ("cancel", .bool true),
      ("detailed_events", .bool true),
      ("artifacts", .bool true)
    ])
  ]

  -- 3. Hermes / Paloma (`paloma`)
  let hermesOwner ← getEnvTrimmed "HERMES_CLOUD_OWNER"
  let hermesOwnerOk ← matchesCloudOwner store hermesOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  let (hermesAvail, hermesReason) ←
    if !hermesOwnerOk then
      pure (false, JVal.str "Hermes is not connected for this account")
    else
      let (_, _, _, capsOpt, errOpt) ← resolveEffectiveHermesEndpoint serverPort
      match capsOpt with
      | some _ => pure (true, JVal.null)
      | none => pure (false, JVal.str (errOpt.getD "Hermes is not responding; other cloud services remain available"))

  let palomaObj : JVal := .obj #[
    ("id", .str "paloma"),
    ("provider", .str "hermes"),
    ("label", .str "Paloma"),
    ("available", .bool hermesAvail),
    ("experimental", .bool false),
    ("reason", hermesReason),
    ("capabilities", .obj #[
      ("models", .bool true),
      ("attachments", .bool true),
      ("repository", .bool false),
      ("follow_up", .bool true),
      ("cancel", .bool true),
      ("detailed_events", .bool true),
      ("artifacts", .bool false)
    ])
  ]

  let result : JVal := .arr #[grokObj, cursorObj, palomaObj]
  hub.mu.atomically do
    let st ← get
    set { st with accountsCache := putCachedJson st.accountsCache cacheKey nowSec result }
  return result

def buildCloudUsageJson
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (callerUserId callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool) : IO JVal := do
  let grokOwner ← getEnvTrimmed "GROK_BOT_OWNER"
  let grokOwnerOk ← matchesCloudOwner store grokOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  let cursorOwner ← getEnvTrimmed "CURSOR_CLOUD_OWNER"
  let cursorOwnerOk ← matchesCloudOwner store cursorOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  if !grokOwnerOk && !cursorOwnerOk then
    return .obj #[("accounts", .obj #[])]
  let nowSec ← nowEpoch
  let cacheKey := s!"usage:{callerUserId}:{grokOwnerOk}:{cursorOwnerOk}"
  let cached? ← hub.mu.atomically do
    let st ← get
    return getCachedJson? st.usageCache cacheKey nowSec 60
  if let some hit := cached? then
    return hit
  let mut acctFields : Array (String × JVal) := #[]
  let grokCredFile ← getEnvTrimmed "GROK_BOT_CREDENTIAL_FILE"
  if grokOwnerOk && !grokCredFile.isEmpty then
    if let some raw ← (try some <$> IO.FS.readFile grokCredFile catch _ => pure none) then
      if let .ok credJv := OrbBin.Json.parse raw then
        let tok := ((credJv.fieldStr? "access_token").getD "").trimAscii.toString
        if !tok.isEmpty then
          if let .ok (200, _, some sandJv) ← sendJsonRequest "POST"
              "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
              (some tok) (some (.obj #[])) #[("Connect-Protocol-Version", "1")] 4000 262144 then
            let pooled := (sandJv.fieldBool? "usesPooledEnterpriseAllowance").getD false
            let hasLimit := (sandJv.fieldBool? "hasNonZeroIncludedLimit").getD false
            if !pooled && hasLimit then
              if let some (.num pctRaw) := sandJv.field? "usagePercent" then
                let resetVal := (sandJv.field? "resetAt").getD .null
                acctFields := acctFields.push ("grok-default", .obj #[
                  ("windows", .arr #[.obj #[("label", .str "Weekly"), ("used_percent", .num pctRaw)]]),
                  ("details", .arr #[]),
                  ("reset_at", resetVal),
                  ("source", .str "account_dashboard")
                ])
          if cursorOwnerOk then
            if let .ok (200, _, some periodJv) ← sendJsonRequest "POST"
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
                (some tok) (some (.obj #[])) #[("Connect-Protocol-Version", "1")] 4000 262144 then
              if let some planJv := periodJv.field? "planUsage" then
                if let some (.num totPct) := planJv.field? "totalPercentUsed" then
                  let mut details : Array JVal := #[]
                  if let some (.num autoPct) := planJv.field? "autoPercentUsed" then
                    details := details.push (.obj #[("label", .str "Auto + Composer"), ("used_percent", .num autoPct)])
                  if let some (.num apiPct) := planJv.field? "apiPercentUsed" then
                    details := details.push (.obj #[("label", .str "API"), ("used_percent", .num apiPct)])
                  let resetMs := (periodJv.field? "billingCycleEnd").getD .null
                  acctFields := acctFields.push ("cursor-default", .obj #[
                    ("windows", .arr #[.obj #[("label", .str "Total"), ("used_percent", .num totPct)]]),
                    ("details", .arr details),
                    ("reset_at_ms", resetMs),
                    ("source", .str "account_dashboard")
                  ])
  let res : JVal := .obj #[
    ("accounts", .obj acctFields),
    ("checked_at", .str (formatEpochIso8601Utc nowSec))
  ]
  hub.mu.atomically do
    let st ← get
    set { st with usageCache := putCachedJson st.usageCache cacheKey nowSec res }
  return res

/-! ## Hermes Options, Hermes Settings (`GET`/`PUT`) & Cursor Options -/

private def defaultHermesEfforts : Array JVal := #[
  .obj #[("id", .str ""), ("name", .str "Default")],
  .obj #[("id", .str "none"), ("name", .str "Off")],
  .obj #[("id", .str "low"), ("name", .str "Low")],
  .obj #[("id", .str "medium"), ("name", .str "Medium")],
  .obj #[("id", .str "high"), ("name", .str "High")],
  .obj #[("id", .str "xhigh"), ("name", .str "Extra High")]
]

private def collectHermesModelItems (store : CoreStore) (hermesUrl : String) (apiKey : String) : IO (Array JVal) := do
  let mut items : Array JVal := #[.obj #[("id", .str ""), ("name", .str "Profile default")]]
  let mut seen : Array String := #[""]
  -- Builtin routing chains from SQLite `model_routing_chains`
  if let .ok rows ← execParamQuery store.missionsDb "SELECT id, name FROM model_routing_chains ORDER BY id ASC;" #[] then
    for i in [1:rows.size] do
      let cid := ((rows[i]![0]?).getD "").trimAscii.toString
      let cname := ((rows[i]![1]?).getD cid).trimAscii.toString
      if !cid.isEmpty then
        let mid := if cid.startsWith "builtin/" then cid else s!"builtin/{cid}"
        if !seen.contains mid then
          seen := seen.push mid
          items := items.push (.obj #[("id", .str mid), ("name", .str s!"{cname} · {mid}")])
  for stdId in #["builtin/smart", "builtin/fast", "builtin/code", "builtin/deep"] do
    if !seen.contains stdId then
      seen := seen.push stdId
      items := items.push (.obj #[("id", .str stdId), ("name", .str stdId)])
  -- Hermes `/v1/models`
  if let .ok (code, _, some mJv) ← sendJsonRequest "GET" s!"{hermesUrl}/v1/models" (some apiKey) none #[] 2500 524288 then
    if 200 ≤ code && code < 300 then
      let arr := (mJv.fieldArr? "data").orElse (fun _ => mJv.fieldArr? "items") |>.getD #[]
      for entry in arr do
        let mid := ((entry.fieldStr? "id").getD "").trimAscii.toString
        if !mid.isEmpty && mid != "hermes-agent" && !seen.contains mid then
          seen := seen.push mid
          let nm := (entry.fieldStr? "displayName").orElse (fun _ => entry.fieldStr? "name") |>.getD mid
          items := items.push (.obj #[("id", .str mid), ("name", .str nm)])
  return items

/-- Minimal indentation-aware YAML scalar reader for `/var/lib/hermes-assistant/config.yaml`. -/
private def leadingSpacesCount (s : String) : Nat :=
  (s.toList.takeWhile (· == ' ')).length

private def yamlFindScalar? (yamlText : String) (sectionPath : List String) (key : String) : Option String := Id.run do
  let lines := yamlText.splitOn "\n"
  let mut stack : Array (Nat × String) := #[]
  for rawLine in lines do
    let noComment := (rawLine.splitOn " #").headD rawLine
    let trimmed := noComment.trimAscii.toString
    if !trimmed.isEmpty && !trimmed.startsWith "#" && !trimmed.startsWith "-" then
      let indent := leadingSpacesCount rawLine
      while stack.size > 0 && (stack.back!.1) >= indent do
        stack := stack.pop
      match trimmed.splitOn ":" with
      | [] => pure ()
      | kPart :: rest =>
        let k := kPart.trimAscii.toString
        let vRaw := (String.intercalate ":" rest).trimAscii.toString
        if vRaw.isEmpty then
          stack := stack.push (indent, k)
        else
          let curPath := (stack.map Prod.snd).toList
          if curPath == sectionPath && k == key then
            return some (trimQuotes vRaw)
  return none

private def isPrefixOfList (pfx full : List String) : Bool :=
  match pfx, full with
  | [], _ => true
  | _ :: _, [] => false
  | a :: ar, b :: br => a == b && isPrefixOfList ar br

/-- Indentation-aware YAML scalar updater supporting both top-level (`["model"]`) and nested
    (`["display", "platforms", "telegram"]`) section paths without clobbering unrelated keys. -/
private def yamlUpdatePathScalar (yamlText : String) (sectionPath : List String) (key newVal : String) : String := Id.run do
  let lines := if yamlText.isEmpty then ([] : List String) else yamlText.splitOn "\n"
  let mut stack : Array (Nat × String) := #[]
  let mut out : Array String := #[]
  let mut replaced := false
  let mut bestMatchLen : Nat := 0
  let mut bestInsertPos : Nat := 0
  let mut bestChildIndent : Nat := 0
  for rawLine in lines do
    let noComment := (rawLine.splitOn " #").headD rawLine
    let trimmed := noComment.trimAscii.toString
    if trimmed.isEmpty || trimmed.startsWith "#" || trimmed.startsWith "-" then
      out := out.push rawLine
    else
      let indent := leadingSpacesCount rawLine
      while stack.size > 0 && (stack.back!.1) >= indent do
        stack := stack.pop
      match trimmed.splitOn ":" with
      | [] => out := out.push rawLine
      | kPart :: rest =>
        let k := kPart.trimAscii.toString
        let vRaw := (String.intercalate ":" rest).trimAscii.toString
        let curPath := (stack.map Prod.snd).toList
        if vRaw.isEmpty then
          let nextPath := curPath ++ [k]
          stack := stack.push (indent, k)
          out := out.push rawLine
          if isPrefixOfList nextPath sectionPath && nextPath.length >= bestMatchLen then
            bestMatchLen := nextPath.length
            bestInsertPos := out.size
            bestChildIndent := indent + 2
        else if !replaced && curPath == sectionPath && k == key then
          let pad := String.ofList (List.replicate indent ' ')
          out := out.push s!"{pad}{key}: {newVal}"
          replaced := true
        else
          out := out.push rawLine
          if !curPath.isEmpty && isPrefixOfList curPath sectionPath && curPath.length >= bestMatchLen then
            bestMatchLen := curPath.length
            bestInsertPos := out.size
            bestChildIndent := indent
  if replaced then
    return String.intercalate "\n" out.toList
  let mut insertLines : Array String := #[]
  let mut curIndent := if bestMatchLen == 0 then 0 else bestChildIndent
  for sec in sectionPath.drop bestMatchLen do
    let pad := String.ofList (List.replicate curIndent ' ')
    insertLines := insertLines.push s!"{pad}{sec}:"
    curIndent := curIndent + 2
  let valPad := String.ofList (List.replicate curIndent ' ')
  insertLines := insertLines.push s!"{valPad}{key}: {newVal}"
  let finalLines :=
    if bestMatchLen == 0 then
      out ++ insertLines
    else
      (out.extract 0 bestInsertPos) ++ insertLines ++ (out.extract bestInsertPos out.size)
  return String.intercalate "\n" finalLines.toList

private def yamlUpdateTopScalar (yamlText sectionName key newVal : String) : String :=
  yamlUpdatePathScalar yamlText [sectionName] key newVal

/-- Parse a non-negative decimal number string (e.g. `"0.5"`, `"0.95"`) into milli-units (`500`, `950`). -/
private def parseNonNegDecimalMilli? (raw : String) : Option Nat := do
  let t := raw.trimAscii.toString
  if t.isEmpty || t.startsWith "-" then none
  match t.splitOn "." with
  | [wholeStr] =>
    let w ← wholeStr.toNat?
    some (w * 1000)
  | [wholeStr, fracStr] =>
    let w ← if wholeStr.isEmpty then some 0 else wholeStr.toNat?
    if fracStr.isEmpty then some (w * 1000)
    else
      let chars := fracStr.toList
      if !chars.all Char.isDigit then none
      let padded := (chars ++ ['0', '0', '0']).take 3
      let f ← (String.ofList padded).toNat?
      some (w * 1000 + f)
  | _ => none

private def upsertEnvLine (content key val : String) : String := Id.run do
  let lines := content.splitOn "\n"
  let mut found := false
  let mut out : Array String := #[]
  for line in lines do
    let t := line.trimAscii.toString
    if t.startsWith s!"{key}=" || t.startsWith s!"export {key}=" then
      out := out.push s!"{key}={val}"
      found := true
    else
      out := out.push line
  if !found then
    out := out.push s!"{key}={val}"
  return String.intercalate "\n" out.toList

def buildHermesSettingsPayload
    (store : CoreStore)
    (serverPort : UInt16) : IO JVal := do
  let (rtName, hermesUrl, apiKey?, capsFromProbe?, _) ← resolveEffectiveHermesEndpoint serverPort
  let homeDir ← assistantHomeDir rtName
  let cfgPath := s!"{homeDir}/config.yaml"
  let soulPath := s!"{homeDir}/SOUL.md"
  let serviceName := s!"{rtName}.service"
  let isHermetic := (← getEnvTrimmed "ORB_HERMETIC_TEST") == "1" || !(← getEnvTrimmed "HERMES_HOME").isEmpty
  let serviceActive ←
    if isHermetic then pure capsFromProbe?.isSome
    else
      let (rcSvc, _) ← runShortCmd "systemctl" #["is-active", "--quiet", serviceName]
      pure (rcSvc == 0)
  let envPaths ← assistantEnvPaths rtName
  let mut envPresent := false
  for ep in envPaths do
    if (← (System.FilePath.mk ep).pathExists) then envPresent := true
  let configPresent ← (System.FilePath.mk cfgPath).pathExists
  let yamlRaw ← if configPresent then (try IO.FS.readFile cfgPath catch _ => pure "") else pure ""
  let soulMd ← if (← (System.FilePath.mk soulPath).pathExists) then (try IO.FS.readFile soulPath catch _ => pure "") else pure ""

  let envModel ← lookupEnvFileKey? envPaths "HERMES_ASSISTANT_MODEL"
  let envBaseUrl ← lookupEnvFileKey? envPaths "OPENAI_BASE_URL"
  let tgTok ← lookupEnvFileKey? envPaths "TELEGRAM_BOT_TOKEN"
  let tokenPresent := (tgTok.getD "").length > 0 || apiKey?.isSome

  let expectedBase := s!"http://127.0.0.1:{serverPort}/v1"
  let defaultModel := (yamlFindScalar? yamlRaw ["model"] "default").orElse (fun _ => envModel) |>.getD "builtin/smart"
  let provider := (yamlFindScalar? yamlRaw ["model"] "provider").getD "custom"
  let baseUrl := (yamlFindScalar? yamlRaw ["model"] "base_url").orElse (fun _ => envBaseUrl) |>.getD expectedBase
  let apiMode := (yamlFindScalar? yamlRaw ["model"] "api_mode").getD "chat_completions"
  let reasoningEffort := (yamlFindScalar? yamlRaw ["model"] "reasoning_effort").getD ""
  let usesProxy := (baseUrl.splitOn "127.0.0.1").length > 1 || (baseUrl.splitOn "localhost").length > 1
  let memEnabled := ((yamlFindScalar? yamlRaw ["memory"] "memory_enabled").getD "true").toLower != "false"
  let profEnabled := ((yamlFindScalar? yamlRaw ["memory"] "user_profile_enabled").getD "true").toLower != "false"
  let memCharLim := ((yamlFindScalar? yamlRaw ["memory"] "memory_char_limit").bind String.toNat?).getD 8000
  let usrCharLim := ((yamlFindScalar? yamlRaw ["memory"] "user_char_limit").bind String.toNat?).getD 4000
  let compEnabled := ((yamlFindScalar? yamlRaw ["compression"] "enabled").getD "true").toLower != "false"
  let compThreshRaw := (yamlFindScalar? yamlRaw ["compression"] "threshold").getD "0.5"
  let termBackend := (yamlFindScalar? yamlRaw ["terminal"] "backend").getD "local"
  let termCwd := (yamlFindScalar? yamlRaw ["terminal"] "cwd").getD ""
  let tgProgress := (yamlFindScalar? yamlRaw ["display", "platforms", "telegram"] "tool_progress").getD "off"
  let tgCleanup := ((yamlFindScalar? yamlRaw ["display", "platforms", "telegram"] "cleanup_progress").getD "true").toLower != "false"

  -- Session rollup from `{homeDir}/state.db` if readable
  let nowSec ← nowEpoch
  let sinceSec := if nowSec > 259200 then nowSec - 259200 else 0
  let since24h := if nowSec > 86400 then nowSec - 86400 else 0
  let sinceIso := formatEpochIso8601Utc sinceSec
  let mut sessionsAvailable := false
  let mut sessTotal : Nat := 0
  let mut sessAllTime : Nat := 0
  let mut sessActive24h : Nat := 0
  let mut sessTokens : Nat := 0
  let mut sessMsgs : Nat := 0
  let mut sessTools : Nat := 0
  let mut sessOpen : Nat := 0
  let mut bySource : Array (String × JVal) := #[]
  let stateDbPath := s!"{homeDir}/state.db"
  if (← (System.FilePath.mk stateDbPath).pathExists) then
    if let .ok sdb ← openSqliteDb stateDbPath "" then
      if let .ok r1 ← sdb.mu.atomically <| sqliteQueryRowsRaw sdb.handle
          "SELECT COALESCE(source,'api'), COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0), COALESCE(SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END),0) FROM sessions WHERE started_at >= ?1 GROUP BY COALESCE(source,'api');"
          #[toString sinceSec] then
        sessionsAvailable := true
        for i in [1:r1.size] do
          let src := (r1[i]![0]?).getD "api"
          let cnt := ((r1[i]![1]?).bind String.toNat?).getD 0
          let mc := ((r1[i]![2]?).bind String.toNat?).getD 0
          let tc := ((r1[i]![3]?).bind String.toNat?).getD 0
          let op := ((r1[i]![4]?).bind String.toNat?).getD 0
          sessTotal := sessTotal + cnt
          sessMsgs := sessMsgs + mc
          sessTools := sessTools + tc
          sessOpen := sessOpen + op
          bySource := bySource.push (src, JVal.nat cnt)
      if let .ok rAll ← sdb.mu.atomically <| sqliteQueryRowsRaw sdb.handle
          "SELECT COUNT(*), COALESCE(SUM(CASE WHEN started_at >= ?1 THEN 1 ELSE 0 END),0) FROM sessions;"
          #[toString since24h] then
        if rAll.size > 1 then
          sessAllTime := ((rAll[1]![0]?).bind String.toNat?).getD sessTotal
          sessActive24h := ((rAll[1]![1]?).bind String.toNat?).getD 0
      if let .ok rTok ← sdb.mu.atomically <| sqliteQueryRowsRaw sdb.handle
          "SELECT COALESCE(SUM(COALESCE(input_tokens,0) + COALESCE(output_tokens,0)),0) FROM sessions;"
          #[] then
        if rTok.size > 1 then
          sessTokens := ((rTok[1]![0]?).bind String.toNat?).getD 0
      sqliteCloseRaw sdb.handle

  let mut capsJv : JVal := capsFromProbe?.getD (.obj #[])
  let apiServerHealthy := capsFromProbe?.isSome
  let mut jobsTotal : Nat := 0
  let mut jobsEnabled : Nat := 0
  let mut mcpToolsCount : Nat := 0
  if let some toolsArr := capsJv.fieldArr? "tools" then
    mcpToolsCount := toolsArr.size
  let mut modelsArr : Array JVal := #[.obj #[("id", .str ""), ("name", .str "Profile default")]]
  if let some k := apiKey? then
    if let .ok (jc, _, some jj) ← sendJsonRequest "GET" s!"{hermesUrl}/api/jobs?include_disabled=true" (some k) none #[] 1500 262144 then
      if 200 ≤ jc && jc < 300 then
        let jArr := (jj.fieldArr? "jobs").orElse (fun _ => jj.asArr?) |>.getD #[]
        jobsTotal := jArr.size
        jobsEnabled := (jArr.filter (fun j => (j.fieldBool? "enabled").getD true)).size
    modelsArr ← collectHermesModelItems store hermesUrl k

  let cfgSubObj : JVal := .obj #[
    ("default_model", .str defaultModel),
    ("provider", .str provider),
    ("base_url", .str baseUrl),
    ("use_sandboxed_router", .bool usesProxy),
    ("api_mode", .str apiMode),
    ("reasoning_effort", .str reasoningEffort),
    ("memory_enabled", .bool memEnabled),
    ("user_profile_enabled", .bool profEnabled),
    ("memory_char_limit", JVal.nat memCharLim),
    ("user_char_limit", JVal.nat usrCharLim),
    ("compression_enabled", .bool compEnabled),
    ("compression_threshold", .num compThreshRaw),
    ("terminal_backend", .str termBackend),
    ("terminal_cwd", .str termCwd),
    ("telegram_tool_progress", .str tgProgress),
    ("telegram_cleanup_progress", .bool tgCleanup),
    ("mcp_tools_count", JVal.nat mcpToolsCount)
  ]

  return .obj #[
    ("runtime", .obj #[
      ("service_name", .str serviceName),
      ("service_active", .bool serviceActive),
      ("api_server_url", .str hermesUrl),
      ("api_server_healthy", .bool apiServerHealthy),
      ("model", .str defaultModel),
      ("base_url", .str baseUrl),
      ("expected_base_url", .str expectedBase),
      ("uses_sandboxed_proxy", .bool usesProxy),
      ("env_present", .bool envPresent),
      ("config_present", .bool configPresent),
      ("token_present", .bool tokenPresent),
      ("notes", .arr #[])
    ]),
    ("sessions", .obj #[
      ("available", .bool sessionsAvailable),
      ("total_sessions", JVal.nat (if sessAllTime > 0 then sessAllTime else sessTotal)),
      ("active_sessions_24h", JVal.nat sessActive24h),
      ("total_tokens", JVal.nat sessTokens),
      ("since", .str sinceIso),
      ("total", JVal.nat sessTotal),
      ("by_source", .obj bySource),
      ("messages", JVal.nat sessMsgs),
      ("tool_calls", JVal.nat sessTools),
      ("open", JVal.nat sessOpen)
    ]),
    ("home_dir", .str homeDir),
    ("config_path", .str cfgPath),
    ("soul_path", .str soulPath),
    ("default_model", .str defaultModel),
    ("provider", .str provider),
    ("base_url", .str baseUrl),
    ("use_sandboxed_router", .bool usesProxy),
    ("api_mode", .str apiMode),
    ("reasoning_effort", .str reasoningEffort),
    ("memory_enabled", .bool memEnabled),
    ("user_profile_enabled", .bool profEnabled),
    ("memory_char_limit", JVal.nat memCharLim),
    ("user_char_limit", JVal.nat usrCharLim),
    ("compression_enabled", .bool compEnabled),
    ("compression_threshold", .num compThreshRaw),
    ("terminal_backend", .str termBackend),
    ("terminal_cwd", .str termCwd),
    ("telegram_tool_progress", .str tgProgress),
    ("telegram_cleanup_progress", .bool tgCleanup),
    ("mcp_tools_count", JVal.nat mcpToolsCount),
    ("config", cfgSubObj),
    ("soul_markdown", .str soulMd),
    ("capabilities", capsJv),
    ("jobs", .obj #[("total", JVal.nat jobsTotal), ("enabled", JVal.nat jobsEnabled)]),
    ("models", .arr modelsArr),
    ("efforts", .arr defaultHermesEfforts)
  ]

def applyHermesSettingsUpdate
    (store : CoreStore)
    (serverPort : UInt16)
    (reqJv : JVal) : IO (Nat × String × ByteArray) := do
  let validEfforts := #["", "default", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
  let validTgProg := #["off", "new", "edit", "all", "verbose"]
  if let some eff := reqJv.fieldStr? "reasoning_effort" then
    if !validEfforts.contains eff.trimAscii.toString.toLower then
      return jsonErr 400 "Invalid reasoning_effort"
  if let some tgp := reqJv.fieldStr? "telegram_tool_progress" then
    if !validTgProg.contains tgp.trimAscii.toString.toLower then
      return jsonErr 400 "Invalid telegram_tool_progress"
  if let some ctVal := reqJv.field? "compression_threshold" then
    match ctVal with
    | .num ctRaw =>
      match parseNonNegDecimalMilli? ctRaw with
      | some m =>
        if m < 100 || m > 950 then
          return jsonErr 400 "Invalid compression_threshold (expected 0.10..0.95)"
      | none =>
        return jsonErr 400 "Invalid compression_threshold"
    | .null => pure ()
    | _ => return jsonErr 400 "Invalid compression_threshold"

  let (rtName, _, _, _, _) ← resolveEffectiveHermesEndpoint serverPort
  let homeDir ← assistantHomeDir rtName
  let homeFp := System.FilePath.mk homeDir
  let cfgPath := System.FilePath.mk s!"{homeDir}/config.yaml"
  let soulPath := System.FilePath.mk s!"{homeDir}/SOUL.md"

  if (← cfgPath.pathExists) || (← homeFp.pathExists) then
    let mut yaml ← if (← cfgPath.pathExists) then (try IO.FS.readFile cfgPath catch _ => pure "") else pure ""
    if let some dm := reqJv.fieldStr? "default_model" then
      let dmt := dm.trimAscii.toString
      if !dmt.isEmpty then
        yaml := yamlUpdateTopScalar yaml "model" "default" s!"\"{dmt}\""
    if let some re := reqJv.fieldStr? "reasoning_effort" then
      let ret := re.trimAscii.toString.toLower
      let norm := if ret == "default" then "" else ret
      yaml := yamlUpdateTopScalar yaml "model" "reasoning_effort" s!"\"{norm}\""
    if let some useRouter := reqJv.fieldBool? "use_sandboxed_router" then
      if useRouter then
        yaml := yamlUpdateTopScalar yaml "model" "provider" "\"custom\""
        yaml := yamlUpdateTopScalar yaml "model" "base_url" s!"\"http://127.0.0.1:{serverPort}/v1\""
    if let some me := reqJv.fieldBool? "memory_enabled" then
      yaml := yamlUpdateTopScalar yaml "memory" "memory_enabled" (if me then "true" else "false")
    if let some pe := reqJv.fieldBool? "user_profile_enabled" then
      yaml := yamlUpdateTopScalar yaml "memory" "user_profile_enabled" (if pe then "true" else "false")
    if let some mcl := reqJv.fieldNat? "memory_char_limit" then
      let clamped := Nat.min 200000 (Nat.max 500 mcl)
      yaml := yamlUpdateTopScalar yaml "memory" "memory_char_limit" (toString clamped)
    if let some ucl := reqJv.fieldNat? "user_char_limit" then
      let clamped := Nat.min 200000 (Nat.max 250 ucl)
      yaml := yamlUpdateTopScalar yaml "memory" "user_char_limit" (toString clamped)
    if let some ce := reqJv.fieldBool? "compression_enabled" then
      yaml := yamlUpdateTopScalar yaml "compression" "enabled" (if ce then "true" else "false")
    if let some (.num ctRaw) := reqJv.field? "compression_threshold" then
      yaml := yamlUpdateTopScalar yaml "compression" "threshold" ctRaw
    if let some tgp := reqJv.fieldStr? "telegram_tool_progress" then
      let tgNorm := tgp.trimAscii.toString.toLower
      yaml := yamlUpdatePathScalar yaml ["display", "platforms", "telegram"] "tool_progress" s!"\"{tgNorm}\""
    if let some tgc := reqJv.fieldBool? "telegram_cleanup_progress" then
      yaml := yamlUpdatePathScalar yaml ["display", "platforms", "telegram"] "cleanup_progress" (if tgc then "true" else "false")
    if let .error e ← writeAtomicPrivate0600 cfgPath yaml.toUTF8 then
      return jsonErr 500 s!"Failed writing config.yaml: {e}"

  if let some soul := reqJv.fieldStr? "soul_markdown" then
    if (← homeFp.pathExists) then
      let _ ← writeAtomicPrivate0600 soulPath soul.toUTF8

  if let some dm := reqJv.fieldStr? "default_model" then
    let dmt := dm.trimAscii.toString
    if !dmt.isEmpty then
      let envPaths ← assistantEnvPaths rtName
      for ep in envPaths do
        let efp := System.FilePath.mk ep
        if (← efp.pathExists) then
          if let some cur ← (try some <$> IO.FS.readFile efp catch _ => pure none) then
            let updated := upsertEnvLine cur "HERMES_ASSISTANT_MODEL" dmt
            let _ ← writeAtomicPrivate0600 efp updated.toUTF8

  let isHermetic := (← getEnvTrimmed "ORB_HERMETIC_TEST") == "1" || !(← getEnvTrimmed "HERMES_HOME").isEmpty
  if (reqJv.fieldBool? "restart_service").getD false && !isHermetic then
    let _ ← runShortCmd "systemctl" #["restart", s!"{rtName}.service"]

  let payload ← buildHermesSettingsPayload store serverPort
  return jsonResp 200 payload

/-! ## Cloud Execution SQLite Persistence & Worker Engine -/

private def phaseMissionStatus (phase : String) : String :=
  match phase with
  | "response_complete" | "waiting_user" => "awaiting_user"
  | "failed" | "incompatible" => "failed"
  | "cancelled" => "interrupted"
  | "reconnect_required" | "submission_uncertain" => "blocked"
  | _ => "active"

private def isPhaseTerminal (phase : String) : Bool :=
  phase == "response_complete" || phase == "failed" || phase == "cancelled" ||
  phase == "incompatible" || phase == "reconnect_required" || phase == "submission_uncertain"

private def cloudBackendForProvider (provider : String) : String :=
  match provider with
  | "grok_bot" => "cloud_grok_bot"
  | "cursor_cloud" => "cloud_cursor"
  | _ => "cloud_hermes"

private def sha256HexStr (s : String) : String :=
  bytesToHexLower (sha256Bytes s.toUTF8)

def loadCloudExecutionJson? (store : CoreStore) (missionId : String) : IO (Option (Nat × JVal)) := do
  let rows ← execParamQuery store.missionsDb
    "SELECT COALESCE(revision,0), COALESCE(data,'{}'), provider, prompt, response_text, status, COALESCE(request_key,'') FROM cloud_executions WHERE mission_id=?1 ORDER BY revision DESC, rowid DESC LIMIT 1;"
    #[missionId]
  let .ok rs := rows | return none
  if rs.size ≤ 1 then return none
  let r := rs[1]!
  let rev := ((r[0]?).bind String.toNat?).getD 0
  let dataStr := (r[1]?).getD "{}"
  match OrbBin.Json.parse dataStr with
  | .ok jv@(.obj kvs) =>
    if !kvs.isEmpty && (jv.fieldStr? "mission_id").isSome then
      return some (rev, jv.setField "revision" (JVal.nat rev))
    let prov := (r[2]?).getD "hermes"
    let prompt := (r[3]?).getD ""
    let resp := (r[4]?).getD ""
    let st := (r[5]?).getD "response_complete"
    let rk := (r[6]?).getD missionId
    let synth : JVal := .obj #[
      ("parent_mission_id", .null),
      ("mission_id", .str missionId),
      ("request_key", .str rk),
      ("request_signature", .str (sha256HexStr s!"{prov}:{prompt}")),
      ("revision", JVal.nat rev),
      ("selection", .obj #[
        ("provider", .str prov),
        ("account", .str (if prov == "cursor_cloud" then "cursor-default" else if prov == "grok_bot" then "grok-default" else "paloma")),
        ("repository", .null),
        ("git_ref", .null),
        ("model", .null)
      ]),
      ("external_id", .null),
      ("external_url", .null),
      ("turns", .arr #[.obj #[
        ("key", .str rk),
        ("prompt", .str prompt),
        ("phase", .str (if st == "completed" then "response_complete" else st)),
        ("external_id", .null),
        ("cursor", .null),
        ("result", if resp.isEmpty then .null else .str resp),
        ("detail", .null),
        ("artifacts", .arr #[]),
        ("branches", .arr #[]),
        ("usage", .null)
      ]])
    ]
    return some (rev, synth)
  | _ => return none

private def saveCloudExecutionCas
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId requestKey provider : String)
    (expectedRev? : Option Nat)
    (execJv : JVal)
    (newTurnAdded : Bool := false) : IO (Except String JVal) := do
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let nextRev := match expectedRev? with | some r => r + 1 | none => 0
  let stamped := execJv.setField "revision" (JVal.nat nextRev)
  let dataStr := renderCompact stamped
  let turns := (stamped.fieldArr? "turns").getD #[]
  let activeOrLast := (turns.find? (fun t => !isPhaseTerminal ((t.fieldStr? "phase").getD "queued"))).orElse (fun _ => turns.back?)
  let turnPhase := (activeOrLast.bind (fun t => t.fieldStr? "phase")).getD "queued"
  let nextMissionStatus := phaseMissionStatus turnPhase
  let lastPrompt := (turns.back?.bind (fun t => t.fieldStr? "prompt")).getD ""
  let lastRes := (turns.back?.bind (fun t => t.fieldStr? "result")).getD ""

  match expectedRev? with
  | none =>
    let ins ← execParamStmt store.missionsDb
      ("INSERT INTO cloud_executions (id, mission_id, provider, prompt, response_text, status, request_key, revision, data, created_at, updated_at) " ++
       "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8, ?9, ?9);")
      #[missionId, missionId, provider, lastPrompt, lastRes, turnPhase, requestKey, dataStr, nowIso]
    if let .error e := ins then return .error e
  | some expRev =>
    let upd ← execParamQuery store.missionsDb
      ("UPDATE cloud_executions SET revision=?3, data=?4, prompt=?5, response_text=?6, status=?7, updated_at=?8 " ++
       "WHERE mission_id=?1 AND revision=?2 RETURNING revision;")
      #[missionId, toString expRev, toString nextRev, dataStr, lastPrompt, lastRes, turnPhase, nowIso]
    match upd with
    | .error e => return .error e
    | .ok urs =>
      if urs.size ≤ 1 then
        return .error "cas_conflict"

  -- Record `assistant_message` into `mission_events` once per completed turn key
  for t in turns do
    let ph := (t.fieldStr? "phase").getD ""
    let tKey := (t.fieldStr? "key").getD ""
    let tRes := (t.fieldStr? "result").getD ""
    if ph == "response_complete" && !tKey.isEmpty && !tRes.trimAscii.toString.isEmpty then
      let chk ← execParamQuery store.missionsDb
        "SELECT 1 FROM mission_events WHERE mission_id=?1 AND event_id=?2 LIMIT 1;"
        #[missionId, tKey]
      let existsAlready := match chk with | .ok crs => crs.size > 1 | .error _ => false
      if !existsAlready then
        let payload := renderCompact (.obj #[("content", .str tRes), ("id", .str tKey)])
        let seqRes ← appendMissionEvent store missionId "assistant_message" payload nowIso
        if let .ok seq := seqRes then
          let _ ← execParamStmt store.missionsDb
            "UPDATE mission_events SET event_id=?3, content=?4 WHERE mission_id=?1 AND seq=?2;"
            #[missionId, toString seq, tKey, tRes]

  -- Sync `missions.status` and `updated_at`
  let statusClause :=
    if newTurnAdded then
      "status=?2, updated_at=?3, state_revision=state_revision+1"
    else
      "status=CASE WHEN status='acknowledged' THEN 'acknowledged' ELSE ?2 END, updated_at=?3, state_revision=state_revision+1"
  let _ ← execParamStmt store.missionsDb
    s!"UPDATE missions SET {statusClause} WHERE id=?1;"
    #[missionId, nextMissionStatus, nowIso]

  publishControlEvent broadcastHub? "mission_status_changed" (renderCompact (.obj #[
    ("type", .str "mission_status_changed"),
    ("mission_id", .str missionId),
    ("status", .str nextMissionStatus),
    ("updated_at", .str nowIso)
  ])) (some missionId)

  return .ok stamped

private def appendCloudEventRow
    (store : CoreStore)
    (missionId runId eventId kind : String)
    (dataJv : JVal) : IO Unit := do
  let _ ← execParamStmt store.missionsDb
    "INSERT OR IGNORE INTO cloud_events (mission_id, run_id, event_id, kind, data) VALUES (?1, ?2, ?3, ?4, ?5);"
    #[missionId, runId, eventId, kind, renderCompact dataJv]

private def orbFormattingInstructions : String :=
  "You are answering in Orb, which renders GitHub-flavoured Markdown (headings, lists, code fences, tables). Markdown is welcome. When output is tabular, write a GFM table: a header row, a separator row such as `| --- | ---: |`, and leading and trailing pipes on every row. Never write bare `a | b | c` lines without the separator row."

def effortToHermesReasoning? (rawEffort : String) : Option JVal :=
  match rawEffort.trimAscii.toString.toLower with
  | "none" => some (.obj #[("enabled", .bool false)])
  | "minimal" => some (.obj #[("enabled", .bool true), ("effort", .str "minimal")])
  | "low" => some (.obj #[("enabled", .bool true), ("effort", .str "low")])
  | "medium" => some (.obj #[("enabled", .bool true), ("effort", .str "medium")])
  | "high" => some (.obj #[("enabled", .bool true), ("effort", .str "high")])
  | "xhigh" => some (.obj #[("enabled", .bool true), ("effort", .str "xhigh")])
  | "max" => some (.obj #[("enabled", .bool true), ("effort", .str "max")])
  | "ultra" => some (.obj #[("enabled", .bool true), ("effort", .str "ultra")])
  | _ => none

private def isSafeHermesRunId (runId : String) : Bool :=
  !runId.isEmpty && runId.toList.all fun c => c.isAlphanum || c == '_' || c == '-'

private def parseSubmissionEpoch? (cursorStr : String) : Option UInt64 :=
  if cursorStr.startsWith "submission:" then
    ((cursorStr.drop 11).toString.toNat?).map Nat.toUInt64
  else none

private def findLastRunningToolIdx? (steps : Array JVal) (toolName : String) : Option Nat := Id.run do
  let mut idx := steps.size
  while idx > 0 do
    idx := idx - 1
    let s := steps[idx]!
    if (s.fieldStr? "kind") == some "tool" && (s.fieldStr? "status") == some "running" &&
       (s.fieldStr? "name") == some toolName then
      return some idx
  idx := steps.size
  while idx > 0 do
    idx := idx - 1
    let s := steps[idx]!
    if (s.fieldStr? "kind") == some "tool" && (s.fieldStr? "status") == some "running" then
      return some idx
  return none

private def hasOtherPendingTurn (turns : Array JVal) (turnKey : String) : Bool :=
  turns.any (fun t => !isPhaseTerminal ((t.fieldStr? "phase").getD "response_complete") && ((t.fieldStr? "key").getD "") != turnKey)

def tickHermesMission
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16)
    (missionId : String) : IO Bool := do
  let some (rev, execJv) ← loadCloudExecutionJson? store missionId
    | return false
  let turns := (execJv.fieldArr? "turns").getD #[]
  let some turnIdx := turns.findIdx? (fun t => !isPhaseTerminal ((t.fieldStr? "phase").getD "queued"))
    | return false
  let turn := turns[turnIdx]!
  let phase := (turn.fieldStr? "phase").getD "queued"
  let turnKey := (turn.fieldStr? "key").getD "turn-0"
  let prompt := (turn.fieldStr? "prompt").getD ""
  let sel := (execJv.field? "selection").getD (.obj #[])
  let modelStr := ((turn.fieldStr? "model").orElse (fun _ => sel.fieldStr? "model") |>.getD "").trimAscii.toString
  let paramsArr := (turn.fieldArr? "model_params").orElse (fun _ => sel.fieldArr? "model_params") |>.getD #[]
  let effortVal := (paramsArr.findSome? (fun p =>
    let pid := (p.fieldStr? "id").getD ""
    if pid == "effort" || pid == "reasoning_effort" then p.fieldStr? "value" else none)).getD ""
  let reqKey := (execJv.fieldStr? "request_key").getD missionId

  let (_, hermesUrl, apiKey?, capsOpt, capErrOpt) ← resolveEffectiveHermesEndpoint serverPort
  let some apiKey := apiKey?
    | let failedTurn := (turn.setField "phase" (.str "failed")).setField "detail" (.str "Hermes API server key is not configured")
      let nextTurns := turns.set! turnIdx failedTurn
      let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr nextTurns))
      return false

  let simpleId := String.intercalate "" (missionId.splitOn "-")
  let sessionId := (turn.fieldStr? "session_id").orElse (fun _ => execJv.fieldStr? "external_id") |>.getD s!"orb_{simpleId}"

  -- Cancellation requested
  if phase == "cancel_requested" then
    let runId := (turn.fieldStr? "external_id").getD ""
    if runId.isEmpty then
      let cancelledTurn := ((turn.setField "phase" (.str "cancelled")).setField "artifacts" (.arr #[]))
        |>.setField "detail" (.str "Turn interrupted. Continue in the same conversation when ready.")
      let nextTurns := turns.set! turnIdx cancelledTurn
      match ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr nextTurns)) with
      | .error "cas_conflict" => return true
      | _ => return hasOtherPendingTurn turns turnKey
    let stopRes ← sendJsonRequest "POST" s!"{hermesUrl}/v1/runs/{urlEncodeComponent runId}/stop" (some apiKey) (some (.obj #[])) #[] 5000 65536
    let stopConfirmed :=
      match stopRes with
      | .ok (code, _, _) => (200 ≤ code && code < 300) || code == 404 || code == 409
      | .error _ => false
    let mut finalPhase := if stopConfirmed then "cancelled" else "cancel_requested"
    let mut detailVal : JVal :=
      if stopConfirmed then .str "Turn interrupted. Continue in the same conversation when ready."
      else .str "Stopping — awaiting Hermes confirmation"
    let mut finalSteps := (turn.fieldArr? "steps").getD #[]
    let mut finalResult := (turn.field? "result").getD .null
    if let .ok (rCode, _, some runState) ← sendJsonRequest "GET"
        s!"{hermesUrl}/v1/runs/{urlEncodeComponent runId}" (some apiKey) none #[] 5000 524288 then
      if 200 ≤ rCode && rCode < 300 then
        let stStr := ((runState.fieldStr? "status").getD "").trimAscii.toString.toLower
        if let some outStr := (runState.fieldStr? "output").orElse (fun _ => runState.fieldStr? "response") then
          if !outStr.isEmpty then finalResult := .str outStr
        if stStr == "stopping" || stStr == "running" || stStr == "queued" then
          if stStr == "stopping" then
            finalPhase := "cancel_requested"
            detailVal := .str "Stopping — awaiting Hermes confirmation"
        else if stStr == "cancelled" || stStr == "canceled" || stStr == "stopped" || stStr == "aborted" || stStr == "interrupted" then
          finalPhase := "cancelled"
          detailVal := .str "Turn interrupted. Continue in the same conversation when ready."
        else if stStr == "completed" || stStr == "succeeded" || stStr == "done" then
          finalPhase := "response_complete"
          detailVal := .null
        else if stStr == "failed" || stStr == "error" then
          finalPhase := "failed"
          detailVal := .str ((runState.fieldStr? "error").getD "Hermes run failed. The conversation is preserved.")
    if finalPhase != "cancel_requested" then
      finalSteps := finalSteps.map (fun s =>
        if (s.fieldStr? "kind") == some "tool" && (s.fieldStr? "status") == some "running" then
          (s.setField "status" (.str "completed")).setField "done" (.bool true)
        else s.setField "done" (.bool true))
    let mut updTurn := (((turn.setField "phase" (.str finalPhase)).setField "detail" detailVal)
      |>.setField "result" finalResult)
      |>.setField "artifacts" (.arr #[])
    if !finalSteps.isEmpty then
      updTurn := updTurn.setField "steps" (.arr finalSteps)
    if updTurn != turn then
      let nextTurns := turns.set! turnIdx updTurn
      match ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr nextTurns)) with
      | .error "cas_conflict" => return true
      | _ => pure ()
    return !isPhaseTerminal finalPhase || hasOtherPendingTurn turns turnKey

  -- Submit queued (or lost-acceptance `submitting`) turn to Hermes `POST /v1/runs`
  if phase == "queued" || (phase == "submitting" && (turn.fieldStr? "external_id").isNone) then
    if capsOpt.isNone then
      let why := capErrOpt.getD "Hermes is not responding; other cloud services remain available"
      if (why.splitOn "missing durable run replay").length > 1 then
        let incTurn := (turn.setField "phase" (.str "incompatible")).setField "detail" (.str why)
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr (turns.set! turnIdx incTurn)))
        return false
    let nowSec ← nowEpoch
    let (claimedJv, claimingTurn, nextRev) ←
      if phase == "queued" then
        let cTurn := ((turn.setField "phase" (.str "submitting")).setField "session_id" (.str sessionId)).setField "cursor" (.str s!"submission:{nowSec}")
        let claimExec := (execJv.setField "external_id" (.str sessionId)).setField "turns" (.arr (turns.set! turnIdx cTurn))
        match ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) claimExec with
        | .ok cJv => pure (cJv, cTurn, (cJv.fieldNat? "revision").getD (rev + 1))
        | .error _ => return true
      else
        let subAt := (turn.fieldStr? "cursor").bind parseSubmissionEpoch? |>.getD nowSec
        let ageSec := if nowSec ≥ subAt then nowSec - subAt else 0
        if ageSec ≥ 20 * 3600 then
          let uncTurn := (turn.setField "phase" (.str "submission_uncertain")).setField "detail"
            (.str "Submission recovery window expired; inspect Hermes before retrying")
          let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr (turns.set! turnIdx uncTurn)))
          return false
        pure (execJv, turn, rev)
    let mut bodyFields : Array (String × JVal) := #[
      ("input", .str prompt),
      ("session_id", .str sessionId),
      ("instructions", .str orbFormattingInstructions)
    ]
    if !modelStr.isEmpty then
      bodyFields := bodyFields.push ("model", .str modelStr)
    if let some reasoningObj := effortToHermesReasoning? effortVal then
      bodyFields := bodyFields.push ("model_options", .obj #[("reasoning", reasoningObj)])
    let idemHdr := #[("Idempotency-Key", s!"orb:{missionId}:{turnKey}")]
    match ← sendJsonRequest "POST" s!"{hermesUrl}/v1/runs" (some apiKey) (some (.obj bodyFields)) idemHdr 15000 524288 with
    | .ok (code, rawTxt, some runJv) =>
      if 200 ≤ code && code < 300 then
        let runId := ((runJv.fieldStr? "run_id").orElse (fun _ => runJv.fieldStr? "id") |>.getD "").trimAscii.toString
        if isSafeHermesRunId runId then
          let resolvedSess := ((runJv.fieldStr? "session_id").getD sessionId).trimAscii.toString
          let effSess := if resolvedSess.isEmpty then sessionId else resolvedSess
          let runningTurn := ((((claimingTurn.setField "phase" (.str "running")).setField "external_id" (.str runId))
            |>.setField "session_id" (.str effSess)).setField "cursor" (.str "0")).setField "detail" .null
          let runExec := claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx runningTurn))
          let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev) runExec
          return true
        else
          let failTurn := (claimingTurn.setField "phase" (.str "failed")).setField "detail" (.str "Hermes returned invalid or empty run_id")
          let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
            (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx failTurn)))
          return false
      else if code == 401 || code == 403 then
        let reTurn := (claimingTurn.setField "phase" (.str "reconnect_required")).setField "detail"
          (.str "Hermes authorization failed; check API_SERVER_KEY")
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx reTurn)))
        return false
      else if code == 400 || code == 422 then
        let errDetail := (runJv.fieldStr? "error").orElse (fun _ => runJv.fieldStr? "detail") |>.getD rawTxt
        let failTurn := (claimingTurn.setField "phase" (.str "failed")).setField "detail"
          (.str (if errDetail.isEmpty then "Hermes rejected this turn; check the selected model and profile configuration" else errDetail))
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx failTurn)))
        return false
      else
        -- 5xx / 429: lost acceptance stays in `submitting` so next tick replays with identical Idempotency-Key
        let retryTurn := claimingTurn.setField "detail" (.str s!"Hermes returned HTTP {code}; retrying with same idempotency key")
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx retryTurn)))
        return true
    | .ok (code, rawTxt, none) =>
      if code == 401 || code == 403 then
        let reTurn := (claimingTurn.setField "phase" (.str "reconnect_required")).setField "detail"
          (.str "Hermes authorization failed; check API_SERVER_KEY")
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx reTurn)))
        return false
      else if code >= 500 then
        let retryTurn := claimingTurn.setField "detail" (.str s!"Hermes returned HTTP {code}; retrying with same idempotency key")
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx retryTurn)))
        return true
      else
        let failTurn := (claimingTurn.setField "phase" (.str "failed")).setField "detail"
          (.str (if rawTxt.isEmpty then "Hermes rejected run launch" else rawTxt))
        let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx failTurn)))
        return false
    | .error e =>
      -- Transport failure: preserve `submitting` + `submission:<epoch>` for safe idempotent replay within 20h
      let retryTurn := claimingTurn.setField "detail" (.str s!"Hermes connection lost; execution will be reconciled ({e})")
      let _ ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some nextRev)
        (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx retryTurn)))
      return true

  -- Poll running / waiting_user Hermes run
  let runId := (turn.fieldStr? "external_id").getD ""
  if runId.isEmpty then return false
  let curCursor := (turn.fieldStr? "cursor").getD "0"
  let mut nextCursor := if curCursor.startsWith "submission:" || curCursor.isEmpty then "0" else curCursor
  let mut steps := (turn.fieldArr? "steps").getD #[]
  let mut accText := (turn.fieldStr? "result").getD ""
  let mut artifacts := (turn.fieldArr? "artifacts").getD #[]
  let mut detailVal := (turn.field? "detail").getD .null
  let mut resolvedSessionId := sessionId
  let mut usageVal := (turn.field? "usage").getD .null
  let mut morePages := true
  let mut pageCount : Nat := 0
  let mut hasMorePending := false

  -- Paginate durable event journal (`GET /v1/runs/{runId}/events?format=json&after={cursor}`)
  while morePages && pageCount < 8 do
    pageCount := pageCount + 1
    let prevPageCursor := nextCursor
    morePages := false
    if let .ok (evCode, _, some evResp) ← sendJsonRequest "GET"
        s!"{hermesUrl}/v1/runs/{urlEncodeComponent runId}/events?format=json&after={urlEncodeComponent nextCursor}"
        (some apiKey) none #[] 5000 2097152 then
      if 200 ≤ evCode && evCode < 300 then
        let evArr := (evResp.fieldArr? "events").orElse (fun _ => evResp.asArr?) |>.getD #[]
        for ev in evArr do
          let evId := ((ev.fieldStr? "id").orElse (fun _ => (ev.fieldNat? "id").map toString)
            |>.orElse (fun _ => (ev.fieldNat? "seq").map toString) |>.getD "").trimAscii.toString
          let dataObj := (ev.field? "data").getD ev
          let kind := (
            (dataObj.fieldStr? "event")
            |>.orElse (fun _ => ev.fieldStr? "event")
            |>.orElse (fun _ => dataObj.fieldStr? "type")
            |>.orElse (fun _ => ev.fieldStr? "type")
            |>.orElse (fun _ => dataObj.fieldStr? "kind")
            |>.orElse (fun _ => ev.fieldStr? "kind")
            |>.getD "unknown"
          ).trimAscii.toString
          if !evId.isEmpty then
            nextCursor := evId
            appendCloudEventRow store missionId runId evId kind dataObj
          if kind == "message.delta" || kind == "response.output_text.delta" || kind == "text_delta" || kind == "text.delta" then
            let delta := (dataObj.fieldStr? "delta").orElse (fun _ => dataObj.fieldStr? "text") |>.getD ""
            accText := accText ++ delta
          else if kind == "reasoning.available" then
            let txt := ((dataObj.fieldStr? "text").getD "").trimAscii.toString
            if !txt.isEmpty then
              let dup := steps.any (fun s => (s.fieldStr? "kind") == some "think" && ((s.fieldStr? "text").getD "").trimAscii.toString == txt)
              if !dup then
                let tid := if evId.isEmpty then s!"think_{runId}_{steps.size}" else s!"think_{runId}_{evId}"
                steps := steps.push (.obj #[
                  ("kind", .str "think"), ("id", .str tid), ("text", .str txt),
                  ("done", .bool true), ("source", .str "event")
                ])
              if accText.isEmpty then
                detailVal := .str "Thinking…"
          else if kind == "reasoning.delta" || kind == "thinking.delta" || kind == "reasoning_delta" || kind == "thinking_delta" then
            let delta := (dataObj.fieldStr? "delta").orElse (fun _ => dataObj.fieldStr? "text") |>.getD ""
            if !delta.isEmpty then
              let tid := s!"think_{runId}"
              if steps.any (fun s => (s.fieldStr? "id") == some tid) then
                steps := steps.map (fun s =>
                  if (s.fieldStr? "id") == some tid then
                    let prev := (s.fieldStr? "text").getD ""
                    s.setField "text" (.str (prev ++ delta))
                  else s)
              else
                steps := steps.push (.obj #[
                  ("kind", .str "think"), ("id", .str tid), ("text", .str delta),
                  ("done", .bool false), ("source", .str "event")
                ])
              if accText.isEmpty then
                detailVal := .str "Thinking…"
          else if kind == "tool.started" || kind == "subagent.start" || kind == "tool_call.started" || kind == "tool.call" || kind == "tool_started" then
            let tName := (dataObj.fieldStr? "tool").orElse (fun _ => dataObj.fieldStr? "name")
              |>.orElse (fun _ => dataObj.fieldStr? "task") |>.getD "tool"
            let callId := (dataObj.fieldStr? "call_id").orElse (fun _ => dataObj.fieldStr? "id")
              |>.getD (if evId.isEmpty then s!"tool_{runId}_{steps.size}" else s!"tool_{runId}_{evId}")
            let preview := (dataObj.fieldStr? "preview").orElse (fun _ => dataObj.fieldStr? "arguments")
              |>.orElse (fun _ => dataObj.fieldStr? "input") |>.getD ""
            let argsVal : JVal :=
              match dataObj.field? "arguments" with
              | some obj@(.obj _) => obj
              | _ =>
                match dataObj.field? "input" with
                | some obj@(.obj _) => obj
                | _ => if preview.isEmpty then .null else .obj #[("preview", .str preview)]
            let inpStr := if !preview.isEmpty then preview else match argsVal with | .obj _ => renderCompact argsVal | _ => ""
            detailVal := .str s!"Using {tName}"
            if !steps.any (fun s => (s.fieldStr? "id") == some callId) then
              steps := steps.push (.obj #[
                ("kind", .str "tool"), ("id", .str callId), ("call_id", .str callId),
                ("name", .str tName), ("status", .str "running"), ("done", .bool false),
                ("input", .str inpStr), ("args", argsVal)
              ])
          else if kind == "tool.completed" || kind == "subagent.complete" || kind == "tool_call.completed" || kind == "tool.result" || kind == "tool_completed" || kind == "tool.failed" || kind == "tool_call.failed" then
            let callId := (dataObj.fieldStr? "call_id").orElse (fun _ => dataObj.fieldStr? "id") |>.getD ""
            let tName := (dataObj.fieldStr? "tool").orElse (fun _ => dataObj.fieldStr? "name") |>.getD "tool"
            let outStr := (dataObj.fieldStr? "preview").orElse (fun _ => dataObj.fieldStr? "summary")
              |>.orElse (fun _ => dataObj.fieldStr? "output") |>.orElse (fun _ => dataObj.fieldStr? "result") |>.getD ""
            let isErr := kind == "tool.failed" || kind == "tool_call.failed" ||
              (dataObj.fieldBool? "error").getD false || (dataObj.fieldStr? "status") == some "failed"
            let finalSt := if isErr then "failed" else "completed"
            let targetIdx? :=
              if !callId.isEmpty then steps.findIdx? (fun s => (s.fieldStr? "id") == some callId)
              else findLastRunningToolIdx? steps tName
            match targetIdx? with
            | some sIdx =>
              let mut stStep := ((steps[sIdx]!.setField "status" (.str finalSt)).setField "done" (.bool true))
              if !outStr.isEmpty then
                stStep := (stStep.setField "output" (.str outStr)).setField "result" (.str outStr)
              if isErr then
                stStep := stStep.setField "error" (.str (if outStr.isEmpty then "Tool failed" else outStr))
              if let some dur := dataObj.field? "duration" then
                stStep := stStep.setField "duration" dur
              steps := steps.set! sIdx stStep
            | none =>
              let fallbackId := if !callId.isEmpty then callId else if evId.isEmpty then s!"tool_{runId}_{steps.size}" else s!"tool_{runId}_{evId}"
              let mut stStep : JVal := .obj #[
                ("kind", .str "tool"), ("id", .str fallbackId), ("call_id", .str fallbackId),
                ("name", .str tName), ("status", .str finalSt), ("done", .bool true),
                ("output", .str outStr), ("result", if outStr.isEmpty then .null else .str outStr)
              ]
              if isErr then
                stStep := stStep.setField "error" (.str (if outStr.isEmpty then "Tool failed" else outStr))
              steps := steps.push stStep
        if let some pageCur := (evResp.fieldStr? "cursor").orElse (fun _ => (evResp.fieldNat? "cursor").map toString) then
          if !pageCur.trimAscii.toString.isEmpty then
            nextCursor := pageCur.trimAscii.toString
        if (evResp.fieldBool? "has_more").getD false then
          if nextCursor != prevPageCursor && !evArr.isEmpty then
            morePages := true
          else
            hasMorePending := true
        else
          hasMorePending := false

  -- Poll run status `GET /v1/runs/{runId}` (unless more event pages still need draining first)
  let mut nextPhase := phase
  if !hasMorePending then
    if let .ok (rCode, _, some runState) ← sendJsonRequest "GET"
        s!"{hermesUrl}/v1/runs/{urlEncodeComponent runId}"
        (some apiKey) none #[] 5000 524288 then
      if 200 ≤ rCode && rCode < 300 then
        if let some sid := runState.fieldStr? "session_id" then
          let sidt := sid.trimAscii.toString
          if !sidt.isEmpty then resolvedSessionId := sidt
        if let some u := runState.field? "usage" then
          if !u.isNull then usageVal := u
        let stStr := ((runState.fieldStr? "status").getD "running").trimAscii.toString.toLower
        let finalOut :=
          (runState.fieldStr? "output").orElse (fun _ => runState.fieldStr? "response")
          |>.orElse (fun _ => runState.fieldStr? "result") |>.getD ""
        if !finalOut.isEmpty then
          accText := finalOut
        if stStr == "completed" || stStr == "succeeded" || stStr == "done" then
          nextPhase := "response_complete"
          detailVal := .null
          artifacts := artifacts.filter (fun a => (a.fieldStr? "kind") != some "hermes_approval")
          steps := steps.map (fun s =>
            if (s.fieldStr? "kind") == some "tool" && (s.fieldStr? "status") == some "running" then
              (s.setField "status" (.str "completed")).setField "done" (.bool true)
            else s.setField "done" (.bool true))
        else if stStr == "waiting_for_approval" || stStr == "awaiting_approval" then
          nextPhase := "waiting_user"
          detailVal := .str "Waiting for your approval"
          if let some reqObj := (runState.field? "approval").orElse (fun _ => runState.field? "pending_approval") then
            artifacts := #[.obj #[
              ("kind", .str "hermes_approval"),
              ("run_id", .str runId),
              ("request", reqObj),
              ("path", .str "")
            ]]
        else if stStr == "stopping" then
          nextPhase := "cancel_requested"
        else if stStr == "cancelled" || stStr == "canceled" || stStr == "stopped" || stStr == "aborted" || stStr == "interrupted" then
          nextPhase := "cancelled"
          detailVal := .str "Turn interrupted. Continue in the same conversation when ready."
          artifacts := artifacts.filter (fun a => (a.fieldStr? "kind") != some "hermes_approval")
          steps := steps.map (fun s => s.setField "done" (.bool true))
        else if stStr == "failed" || stStr == "error" then
          nextPhase := "failed"
          let errTxt := (runState.fieldStr? "error").getD "Hermes run failed. The conversation is preserved."
          detailVal := .str errTxt
          artifacts := artifacts.filter (fun a => (a.fieldStr? "kind") != some "hermes_approval")
        else if stStr == "running" || stStr == "queued" then
          if nextPhase != "cancel_requested" then
            nextPhase := "running"
          artifacts := artifacts.filter (fun a => (a.fieldStr? "kind") != some "hermes_approval")

  -- Deduplicate event-sourced `think` steps that merely echo the final response text
  let trimmedRes := accText.trimAscii.toString
  if !trimmedRes.isEmpty then
    steps := steps.filter fun s =>
      if (s.fieldStr? "kind") != some "think" || (s.fieldStr? "source") != some "event" then true
      else
        let st := ((s.fieldStr? "text").getD "").trimAscii.toString
        !(!st.isEmpty && (trimmedRes.startsWith st || st.startsWith trimmedRes))

  let mut updatedTurn := ((((turn.setField "phase" (.str nextPhase)).setField "cursor" (.str nextCursor))
    |>.setField "session_id" (.str resolvedSessionId)).setField "detail" detailVal)
  updatedTurn := updatedTurn.setField "result" (if accText.isEmpty then .null else .str accText)
  updatedTurn := updatedTurn.setField "artifacts" (.arr artifacts)
  updatedTurn := updatedTurn.setField "usage" usageVal
  if !steps.isEmpty then
    updatedTurn := updatedTurn.setField "steps" (.arr steps)

  if updatedTurn != turn then
    let nextTurns := turns.set! turnIdx updatedTurn
    match ← saveCloudExecutionCas store broadcastHub? missionId reqKey "hermes" (some rev) (execJv.setField "turns" (.arr nextTurns)) with
    | .error "cas_conflict" => return true
    | _ => pure ()

  return hasMorePending || !isPhaseTerminal nextPhase || hasOtherPendingTurn turns turnKey

private def tickCursorMission
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (missionId : String) : IO Bool := do
  let some (rev, execJv) ← loadCloudExecutionJson? store missionId
    | return false
  let turns := (execJv.fieldArr? "turns").getD #[]
  let some turnIdx := turns.findIdx? (fun t => !isPhaseTerminal ((t.fieldStr? "phase").getD "queued"))
    | return false
  let turn := turns[turnIdx]!
  let phase := (turn.fieldStr? "phase").getD "queued"
  let prompt := (turn.fieldStr? "prompt").getD ""
  let cursorKey ← getEnvTrimmed "CURSOR_CLOUD_API_KEY"
  if cursorKey.isEmpty then
    let failTurn := (turn.setField "phase" (.str "failed")).setField "detail" (.str "Cursor Cloud API key is missing")
    let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some rev) (execJv.setField "turns" (.arr (turns.set! turnIdx failTurn)))
    return false
  let basicHdr := #[("Authorization", "Basic " ++ base64Encode s!"{cursorKey}:".toUTF8 false true)]
  let sel := (execJv.field? "selection").getD (.obj #[])
  let agentId := (execJv.fieldStr? "external_id").getD s!"bc-{missionId}"

  if phase == "cancel_requested" then
    let cancelledTurn := turn.setField "phase" (.str "cancelled")
    let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some rev) (execJv.setField "turns" (.arr (turns.set! turnIdx cancelledTurn)))
    return false

  if phase == "queued" then
    let claimingTurn := turn.setField "phase" (.str "submitting")
    let .ok claimedJv ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some rev)
      ((execJv.setField "external_id" (.str agentId)).setField "turns" (.arr (turns.set! turnIdx claimingTurn)))
      | return true
    let nextRev := (claimedJv.fieldNat? "revision").getD (rev + 1)
    let repoUrl := (sel.fieldStr? "repository").getD ""
    let modelVal := (sel.fieldStr? "model").getD ""
    let mut launchFields : Array (String × JVal) := #[("prompt", .obj #[("text", .str prompt)])]
    if !repoUrl.isEmpty then
      launchFields := launchFields.push ("source", .obj #[("repository", .str repoUrl)])
    if !modelVal.isEmpty then
      launchFields := launchFields.push ("model", .str modelVal)
    let targetUrl := if turnIdx == 0 then "https://api.cursor.com/v1/agents" else s!"https://api.cursor.com/v1/agents/{urlEncodeComponent agentId}/followup"
    match ← sendJsonRequest "POST" targetUrl none (some (.obj launchFields)) basicHdr 20000 524288 with
    | .ok (code, rawTxt, some respJv) =>
      if 200 ≤ code && code < 300 then
        let realAgent := (respJv.fieldStr? "id").getD agentId
        let extUrl := (respJv.fieldStr? "url").getD s!"https://cursor.com/agents/{realAgent}"
        let runTurn := (claimingTurn.setField "phase" (.str "running")).setField "external_id" (.str realAgent)
        let nextExec := ((claimedJv.setField "external_id" (.str realAgent)).setField "external_url" (.str extUrl)).setField "turns"
          (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx runTurn))
        let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some nextRev) nextExec
        return true
      else
        let failTurn := (claimingTurn.setField "phase" (.str "failed")).setField "detail" (.str rawTxt)
        let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some nextRev)
          (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx failTurn)))
        return false
    | _ =>
      let failTurn := (claimingTurn.setField "phase" (.str "failed")).setField "detail" (.str "Cursor Cloud launch request failed")
      let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some nextRev)
        (claimedJv.setField "turns" (.arr ((claimedJv.fieldArr? "turns" |>.getD turns).set! turnIdx failTurn)))
      return false

  if let .ok (code, _, some stJv) ← sendJsonRequest "GET" s!"https://api.cursor.com/v1/agents/{urlEncodeComponent agentId}" none none basicHdr 10000 524288 then
    if 200 ≤ code && code < 300 then
      let st := ((stJv.fieldStr? "status").getD "RUNNING").toUpper
      let summary := (stJv.fieldStr? "summary").orElse (fun _ => stJv.fieldStr? "output") |>.getD ""
      let nextPh :=
        if st == "FINISHED" || st == "COMPLETED" || st == "STOPPED" then "response_complete"
        else if st == "FAILED" || st == "ERROR" then "failed"
        else "running"
      let mut updTurn := turn.setField "phase" (.str nextPh)
      if !summary.isEmpty then updTurn := updTurn.setField "result" (.str summary)
      if updTurn != turn then
        let _ ← saveCloudExecutionCas store broadcastHub? missionId ((execJv.fieldStr? "request_key").getD missionId) "cursor_cloud" (some rev)
          (execJv.setField "turns" (.arr (turns.set! turnIdx updTurn)))
      return !isPhaseTerminal nextPh
  return true

/-- Ensure a background worker task is running for `missionId`. -/
def ensureCloudMissionWorker
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16)
    (missionId : String) : IO Unit := do
  let claimed ← tryClaimCloudWorker hub missionId
  if !claimed then return ()
  let _ ← IO.asTask (prio := .dedicated) do
    try
      let mut keepGoing := true
      let mut iter : Nat := 0
      while keepGoing && iter < 3600 do
        iter := iter + 1
        let some (_, execJv) ← loadCloudExecutionJson? store missionId
          | do keepGoing := false
        if keepGoing then
          let prov := (((execJv.field? "selection").getD (.obj #[])).fieldStr? "provider").getD "hermes"
          if prov == "cursor_cloud" then
            keepGoing ← tickCursorMission store broadcastHub? missionId
            if keepGoing then IO.sleep 1500
          else
            keepGoing ← tickHermesMission store broadcastHub? serverPort missionId
            if keepGoing then IO.sleep 400
    catch _ =>
      pure ()
    finally
      releaseCloudWorker hub missionId

/-- Start periodic 2s supervisor loop resuming any non-terminal `cloud_executions` rows. -/
def startCloudSupervisorLoop
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16) : IO Unit := do
  let _ ← IO.asTask (prio := .dedicated) do
    while true do
      if (← store.closedRef.get) then break
      try
        if let .ok rows ← execParamQuery store.missionsDb
            "SELECT DISTINCT mission_id FROM cloud_executions WHERE status NOT IN ('response_complete','completed','failed','cancelled','incompatible','reconnect_required','submission_uncertain') LIMIT 32;"
            #[] then
          for i in [1:rows.size] do
            let mid := ((rows[i]![0]?).getD "").trimAscii.toString
            if !mid.isEmpty then
              ensureCloudMissionWorker hub store broadcastHub? serverPort mid
      catch _ =>
        pure ()
      IO.sleep 2000

/-! ## Cloud Mission Launch (`POST /api/control/missions` with `"cloud"`) & Follow-Up (`POST /api/control/message`) -/

def handleCloudMissionCreate
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16)
    (callerUserId callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool)
    (reqJv cloudSelJv : JVal) : IO (Nat × String × ByteArray) := do
  let prompt := ((reqJv.fieldStr? "prompt").orElse (fun _ => reqJv.fieldStr? "deferred_goal") |>.getD "").trimAscii.toString
  if prompt.isEmpty then
    return jsonErr 400 "Cloud mission requires a non-empty prompt"
  let idemKey := ((reqJv.fieldStr? "idempotency_key").getD "").trimAscii.toString
  if idemKey.isEmpty || idemKey.length > 200 then
    return jsonErr 400 "Cloud mission requires idempotency_key (1..200 chars)"

  -- Reject incompatible local harness / scheduling fields
  for forbidden in #["track", "supersedes_mission_id", "github_pr", "not_before", "deadline", "backend", "agent", "config_profile", "model_override", "model_effort", "remote_node_id", "working_directory"] do
    match reqJv.field? forbidden with
    | some (.str s) => if !s.trimAscii.toString.isEmpty then return jsonErr 400 s!"Field `{forbidden}` is not supported for cloud missions"
    | some (.num _) => return jsonErr 400 s!"Field `{forbidden}` is not supported for cloud missions"
    | some (.obj _) => return jsonErr 400 s!"Field `{forbidden}` is not supported for cloud missions"
    | _ => pure ()
  if (reqJv.fieldBool? "writer").getD false then
    return jsonErr 400 "Field `writer` is not supported for cloud missions"
  if let some wsId := reqJv.fieldStr? "workspace_id" then
    let wst := wsId.trimAscii.toString
    if !wst.isEmpty && wst != "00000000-0000-0000-0000-000000000000" then
      return jsonErr 400 "Field `workspace_id` is not supported for cloud missions"
  if let some atts := reqJv.fieldArr? "attachments" then
    if !atts.isEmpty then
      return jsonErr 400 "Field `attachments` must be empty on cloud mission create"

  let some provEnum := parseCloudProvider? ((cloudSelJv.fieldStr? "provider").getD "")
    | return jsonErr 400 "Unsupported cloud provider"
  let provName := provEnum.name
  let defaultAcct := match provEnum with | .grok => "grok-default" | .cursorCloud => "cursor-default" | .hermes => "paloma"
  let acct := ((cloudSelJv.fieldStr? "account").getD defaultAcct).trimAscii.toString
  let repoStr := ((cloudSelJv.fieldStr? "repository").getD "").trimAscii.toString
  let gitRefStr := ((cloudSelJv.fieldStr? "git_ref").getD "").trimAscii.toString
  let modelStr := ((cloudSelJv.fieldStr? "model").getD "").trimAscii.toString
  let modelParams := (cloudSelJv.fieldArr? "model_params").getD #[]

  if !repoStr.isEmpty then
    if provEnum != .cursorCloud || !repoStr.startsWith "https://github.com/" || repoStr.contains '?' || repoStr.contains '#' || repoStr.contains '@' then
      return jsonErr 400 "Invalid repository URL for cloud selection"
  if !modelParams.isEmpty && provEnum == .grok then
    return jsonErr 400 "model_params not supported for grok_bot"

  let normSel : JVal := .obj (
    (if modelParams.isEmpty then #[] else #[("model_params", JVal.arr modelParams)]) ++ #[
      ("provider", .str provName),
      ("account", .str acct),
      ("repository", if repoStr.isEmpty then .null else .str repoStr),
      ("git_ref", if gitRefStr.isEmpty then .null else .str gitRefStr),
      ("model", if modelStr.isEmpty then .null else .str modelStr)
    ])
  let reqSig := sha256HexStr (renderCompact normSel ++ "\n" ++ prompt)

  -- Authorize cloud owner before any idempotency lookup (zero cross-tenant key oracle)
  let ownerEnvKey := match provEnum with
    | .hermes => "HERMES_CLOUD_OWNER"
    | .cursorCloud => "CURSOR_CLOUD_OWNER"
    | .grok => "GROK_BOT_OWNER"
  let ownerVal ← getEnvTrimmed ownerEnvKey
  let ownerOk ← matchesCloudOwner store ownerVal callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  if !ownerOk then
    let denyMsg := match provEnum with
      | .hermes => "Hermes is not connected for this account"
      | .cursorCloud => "Cursor Cloud is not connected for this account"
      | .grok => "Grok Bot is not connected for this account"
    return jsonErr 403 denyMsg

  -- Idempotent replay check on `request_key`
  if let .ok existingRows ← execParamQuery store.missionsDb
      "SELECT mission_id, COALESCE(data,'{}') FROM cloud_executions WHERE request_key=?1 LIMIT 1;"
      #[idemKey] then
    if existingRows.size > 1 then
      let exMid := (existingRows[1]![0]?).getD ""
      let exData := (existingRows[1]![1]?).getD "{}"
      let ownsEx ← canAccessMission store exMid callerUserId bootstrapAdminId isLegacyUnscoped true
      if ownsEx then
        if let .ok exJv := OrbBin.Json.parse exData then
          if (exJv.fieldStr? "request_signature") == some reqSig then
            if let .ok (some detailJson) ← missionDetailJson store exMid (if isLegacyUnscoped then none else some callerUserId) bootstrapAdminId then
              return (200, "application/json", detailJson.toUTF8)
      return jsonErr 409 "Launch key already used"

  -- Verify target cloud account is available
  let acctsJv ← buildCloudAccountsJson hub store serverPort callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
  let acctsArr := acctsJv.asArr?.getD #[]
  let matchingAcct? := acctsArr.find? (fun a => (a.fieldStr? "id") == some acct && (a.fieldStr? "provider") == some provName)
  let some acctObj := matchingAcct?
    | return jsonErr 400 s!"Unknown cloud account `{acct}` for `{provName}`"
  if !((acctObj.fieldBool? "available").getD false) then
    let why := (acctObj.fieldStr? "reason").getD "Cloud account is not available"
    return jsonErr 403 why

  let mid ← match (reqJv.fieldStr? "id").bind parseUuidCanonical? with
    | some u => pure u
    | none => newUuidV4
  let rawTitle := ((reqJv.fieldStr? "title").getD "").trimAscii.toString
  let autoTitle :=
    if !rawTitle.isEmpty then rawTitle
    else
      let firstLine := ((prompt.splitOn "\n").headD prompt).trimAscii.toString
      if firstLine.length > 72 then (firstLine.take 72).toString ++ "…" else firstLine
  let rawProj := ((reqJv.fieldStr? "project").getD "").trimAscii.toString
  let scopedProj :=
    if rawProj.isEmpty || isLegacyUnscoped || (!bootstrapAdminId.isEmpty && callerUserId == bootstrapAdminId) then rawProj
    else if rawProj.startsWith (callerUserId ++ ":") then rawProj
    else s!"{callerUserId}:{rawProj}"
  let folderVal := normalizeMissionFolder ((reqJv.fieldStr? "folder").getD "")
  let parentMid := ((reqJv.fieldStr? "parent_mission_id").bind parseUuidCanonical?).getD ""
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let backendName := cloudBackendForProvider provName
  let simpleId := String.intercalate "" (mid.splitOn "-")
  let extSessionId := if provEnum == .hermes then s!"orb_{simpleId}" else if provEnum == .cursorCloud then s!"bc-{mid}" else mid
  let tagsJson := "[\"pr-writer\",\"placement:cloud\"]"
  let initHist := renderCompact (.arr #[.obj #[("role", .str "user"), ("content", .str prompt)]])

  let insM ← execParamStmt store.missionsDb
    ("INSERT INTO missions (id, title, status, backend, model_override, model_effort, working_directory, project, folder, placement_revision, " ++
     "parent_mission_id, created_at, updated_at, workspace_id, resumable, requires_local_disk, tags, history_json, authority_mode, placement_kind, owner_user_id) " ++
     "VALUES (?1, ?2, 'active', ?3, ?4, ?5, '', ?6, ?7, 1, ?8, ?9, ?9, '00000000-0000-0000-0000-000000000000', 1, 0, ?10, ?11, 'writer', 'cloud', ?12);")
    #[mid, autoTitle, backendName, modelStr, "", scopedProj, folderVal, parentMid, nowIso, tagsJson, initHist, callerUserId]
  if let .error e := insM then
    return jsonErr 500 s!"Failed creating cloud mission: {e}"

  let uPayload := renderCompact (.obj #[("content", .str prompt), ("id", .str idemKey)])
  let _ ← appendMissionEvent store mid "user_message" uPayload nowIso

  let turn0 : JVal := .obj (
    #[("session_id", .str extSessionId)] ++
    (if modelParams.isEmpty then #[] else #[("model_params", JVal.arr modelParams)]) ++
    #[("model", if modelStr.isEmpty then .null else .str modelStr),
      ("key", .str idemKey),
      ("prompt", .str prompt),
      ("phase", .str "queued"),
      ("external_id", .null),
      ("cursor", .null),
      ("result", .null),
      ("detail", .null),
      ("artifacts", .arr #[]),
      ("branches", .arr #[]),
      ("usage", .null)]
  )
  let execJv : JVal := .obj #[
    ("parent_mission_id", if parentMid.isEmpty then .null else .str parentMid),
    ("mission_id", .str mid),
    ("request_key", .str idemKey),
    ("request_signature", .str reqSig),
    ("revision", JVal.nat 0),
    ("selection", normSel),
    ("external_id", .str extSessionId),
    ("external_url", if provEnum == .cursorCloud then .str s!"https://cursor.com/agents/{extSessionId}" else .null),
    ("turns", .arr #[turn0])
  ]

  if let .error e ← saveCloudExecutionCas store broadcastHub? mid idemKey provName none execJv true then
    return jsonErr 500 s!"Failed saving cloud execution: {e}"

  ensureCloudMissionWorker hub store broadcastHub? serverPort mid

  match ← missionDetailJson store mid (if isLegacyUnscoped then none else some callerUserId) bootstrapAdminId with
  | .ok (some detailJson) => return (200, "application/json", detailJson.toUTF8)
  | _ => return jsonResp 200 (.obj #[("id", .str mid), ("title", .str autoTitle), ("status", .str "active"), ("backend", .str backendName)])

def isCloudMission (store : CoreStore) (missionId : String) : IO Bool := do
  if let .ok rows ← execParamQuery store.missionsDb
      "SELECT 1 FROM cloud_executions WHERE mission_id=?1 LIMIT 1;" #[missionId] then
    if rows.size > 1 then return true
  if let .ok mrows ← execParamQuery store.missionsDb
      "SELECT backend FROM missions WHERE id=?1 LIMIT 1;" #[missionId] then
    if mrows.size > 1 then
      if ((mrows[1]![0]?).getD "").startsWith "cloud_" then return true
  return false

def handleCloudFollowUp
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16)
    (missionId : String)
    (reqJv : JVal) : IO (Nat × String × ByteArray) := do
  let content := ((reqJv.fieldStr? "content").getD "").trimAscii.toString
  if content.isEmpty then
    return jsonErr 400 "Follow-up message content cannot be empty"
  let clientMsgId ←
    match reqJv.fieldStr? "client_message_id" with
    | some rawId =>
      let t := rawId.trimAscii.toString
      if t.isEmpty || t.length > 200 then
        newUuidV4
      else
        match parseUuidCanonical? t with
        | some u => pure u
        | none => pure t
    | none => newUuidV4
  if let some atts := reqJv.fieldArr? "attachments" then
    if !atts.isEmpty then
      return jsonErr 400 "Attachments must be staged into prompt before cloud follow-up"

  let some (rev, execJv) ← loadCloudExecutionJson? store missionId
    | return jsonErr 404 "Cloud mission not found"
  let turns := (execJv.fieldArr? "turns").getD #[]
  if let some existingTurn := turns.find? (fun t => (t.fieldStr? "key") == some clientMsgId) then
    if (existingTurn.fieldStr? "prompt") == some content then
      return jsonResp 200 (.obj #[
        ("id", .str clientMsgId),
        ("queued", .bool true),
        ("message_accepted", .bool true),
        ("mission_id", .str missionId),
        ("warnings", .arr #[])
      ])
    else
      return jsonErr 409 "client_message_id already used with different prompt"

  if turns.any (fun t => let ph := (t.fieldStr? "phase").getD ""; ph == "submission_uncertain" || ph == "incompatible") then
    return jsonErr 409 "Cannot enqueue follow-up while prior cloud turn is uncertain or incompatible"

  let mut sel := (execJv.field? "selection").getD (.obj #[])
  let prov := (sel.fieldStr? "provider").getD "hermes"
  let mut turnModel := sel.field? "model" |>.getD .null
  let mut turnParams := (sel.fieldArr? "model_params").getD #[]

  if prov == "hermes" then
    if let some cm := reqJv.fieldStr? "cloud_model" then
      let cmt := cm.trimAscii.toString
      turnModel := if cmt.isEmpty then .null else .str cmt
      sel := sel.setField "model" turnModel
    if let some cp := reqJv.fieldArr? "cloud_model_params" then
      turnParams := cp
      sel := if cp.isEmpty then sel.removeField "model_params" else sel.setField "model_params" (.arr cp)

  let simpleId := String.intercalate "" (missionId.splitOn "-")
  let sessionId := (execJv.fieldStr? "external_id").getD s!"orb_{simpleId}"
  let newTurn : JVal := .obj (
    #[("session_id", .str sessionId)] ++
    (if turnParams.isEmpty then #[] else #[("model_params", JVal.arr turnParams)]) ++
    #[("model", turnModel),
      ("key", .str clientMsgId),
      ("prompt", .str content),
      ("phase", .str "queued"),
      ("external_id", .null),
      ("cursor", .null),
      ("result", .null),
      ("detail", .null),
      ("artifacts", .arr #[]),
      ("branches", .arr #[]),
      ("usage", .null)]
  )
  let nextExec := (execJv.setField "selection" sel).setField "turns" (.arr (turns.push newTurn))
  let reqKey := (execJv.fieldStr? "request_key").getD missionId
  let nowSec ← nowEpoch
  let nowIso := formatEpochIso8601Utc nowSec
  let _ ← appendMissionEvent store missionId "user_message"
    (renderCompact (.obj #[("content", .str content), ("id", .str clientMsgId)])) nowIso

  match ← saveCloudExecutionCas store broadcastHub? missionId reqKey prov (some rev) nextExec true with
  | .error e => return jsonErr 409 s!"Cloud follow-up conflict: {e}"
  | .ok _ =>
    ensureCloudMissionWorker hub store broadcastHub? serverPort missionId
    return jsonResp 200 (.obj #[
      ("id", .str clientMsgId),
      ("queued", .bool true),
      ("message_accepted", .bool true),
      ("mission_id", .str missionId),
      ("warnings", .arr #[])
    ])

/-! ## Unified HTTP Route Dispatcher for `/api/cloud/*` & `/api/control/missions/:id/cloud*` -/

set_option maxHeartbeats 800000 in
def dispatchCloudHttpRoute
    (hub : CloudRuntimeHub)
    (store : CoreStore)
    (broadcastHub? : Option BroadcastHub)
    (serverPort : UInt16)
    (method cleanPath rawTarget : String)
    (bodyBytes : ByteArray)
    (callerUserId callerUsername bootstrapAdminId : String)
    (isAdmin isLegacyUnscoped : Bool) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (cleanPath.splitOn "/").filter (!·.isEmpty)
  let qMap := parseQueryMap rawTarget

  -- 1. `GET /api/cloud/accounts`
  if method == "GET" && segs == ["api", "cloud", "accounts"] then
    let jv ← buildCloudAccountsJson hub store serverPort callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
    return some (jsonResp 200 jv)

  -- 2. `GET /api/cloud/usage`
  if method == "GET" && segs == ["api", "cloud", "usage"] then
    let jv ← buildCloudUsageJson hub store callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
    return some (jsonResp 200 jv)

  -- 3. `GET /api/cloud/hermes/options`
  if method == "GET" && segs == ["api", "cloud", "hermes", "options"] then
    let hermesOwner ← getEnvTrimmed "HERMES_CLOUD_OWNER"
    let ownerOk ← matchesCloudOwner store hermesOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
    if !ownerOk then
      return some (jsonErr 403 "Hermes is not connected for this account")
    let (_, hermesUrl, apiKey?, _, _) ← resolveEffectiveHermesEndpoint serverPort
    let some apiKey := apiKey?
      | return some (jsonErr 502 "Hermes API server key is not configured")
    let models ← collectHermesModelItems store hermesUrl apiKey
    return some (jsonResp 200 (.obj #[
      ("models", .obj #[("items", .arr models)]),
      ("efforts", .arr defaultHermesEfforts)
    ]))

  -- 4. `GET|PUT /api/cloud/hermes/settings`
  if segs == ["api", "cloud", "hermes", "settings"] then
    let hermesOwner ← getEnvTrimmed "HERMES_CLOUD_OWNER"
    let ownerOk ← matchesCloudOwner store hermesOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
    if !ownerOk then
      return some (jsonErr 403 "Hermes is not connected for this account")
    if method == "GET" then
      let payload ← buildHermesSettingsPayload store serverPort
      return some (jsonResp 200 payload)
    else if method == "PUT" then
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "Invalid JSON body")
      let res ← applyHermesSettingsUpdate store serverPort reqJv
      return some res

  -- 5. `GET /api/cloud/cursor/options`
  if method == "GET" && segs == ["api", "cloud", "cursor", "options"] then
    let cursorOwner ← getEnvTrimmed "CURSOR_CLOUD_OWNER"
    let ownerOk ← matchesCloudOwner store cursorOwner callerUserId callerUsername bootstrapAdminId isAdmin isLegacyUnscoped
    if !ownerOk then
      return some (jsonErr 403 "Cursor Cloud is not connected for this account")
    let cursorKey ← getEnvTrimmed "CURSOR_CLOUD_API_KEY"
    if cursorKey.isEmpty then
      return some (jsonErr 400 "Connect a Cursor Cloud API key on Core")
    let basicHdr := #[("Authorization", "Basic " ++ base64Encode s!"{cursorKey}:".toUTF8 false true)]
    let modelsJv ← match ← sendJsonRequest "GET" "https://api.cursor.com/v1/models" none none basicHdr 10000 524288 with
      | .ok (c, _, some mj) =>
        if 200 ≤ c && c < 300 then pure mj else return some (jsonErr 400 "Failed fetching Cursor Cloud models")
      | _ => return some (jsonErr 400 "Failed fetching Cursor Cloud models")
    let nowSec ← nowEpoch
    let keyHash := sha256HexStr cursorKey
    let cachedRepos? ← hub.mu.atomically do
      let st ← get
      return getCachedJson? st.cursorRepoCache keyHash nowSec 300
    let reposJv ← match cachedRepos? with
      | some hit => pure hit
      | none =>
        match ← sendJsonRequest "GET" "https://api.cursor.com/v1/repositories" none none basicHdr 10000 1048576 with
        | .ok (rc, _, some rj) =>
          let val := if 200 ≤ rc && rc < 300 then rj else JVal.obj #[("items", .arr #[])]
          hub.mu.atomically do
            let st ← get
            set { st with cursorRepoCache := putCachedJson st.cursorRepoCache keyHash nowSec val }
          pure val
        | _ => pure (JVal.obj #[("items", .arr #[])])
    return some (jsonResp 200 (.obj #[("models", modelsJv), ("repositories", reposJv)]))

  -- 6. Mission Cloud Sub-Routes: `/api/control/missions/:id/cloud[/*]`
  if segs.length >= 5 && segs[0]? == some "api" && segs[1]? == some "control" && segs[2]? == some "missions" && segs[4]? == some "cloud" then
    let rawMid := segs[3]!
    let some mid := parseUuidCanonical? rawMid
      | return some (jsonErr 400 "Invalid mission ID")
    let allowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped false
    if !allowed then
      return some (jsonErr 404 "Cloud mission not found")
    let some (rev, execJv) ← loadCloudExecutionJson? store mid
      | return some (jsonErr 404 "Cloud mission not found")

    if method == "GET" && segs.length == 5 then
      return some (jsonResp 200 execJv)

    if method == "GET" && segs.length == 6 && segs[5]? == some "events" then
      let mut out : Array JVal := #[]
      if let .ok rows ← execParamQuery store.missionsDb
          "SELECT run_id, event_id, kind, data FROM (SELECT rowid AS rid, run_id, event_id, kind, data FROM cloud_events WHERE mission_id=?1 ORDER BY rowid DESC LIMIT 500) ORDER BY rid ASC;"
          #[mid] then
        for i in [1:rows.size] do
          let r := rows[i]!
          let dJv := match OrbBin.Json.parse ((r[3]?).getD "{}") with | .ok j => j | .error _ => .obj #[]
          out := out.push (.obj #[
            ("run_id", .str ((r[0]?).getD "")),
            ("id", .str ((r[1]?).getD "")),
            ("kind", .str ((r[2]?).getD "")),
            ("data", dJv)
          ])
      return some (jsonResp 200 (.arr out))

    if method == "GET" && segs.length == 6 && segs[5]? == some "artifact" then
      let artPath := ((qParam? qMap "path").getD "").trimAscii.toString
      if !artPath.startsWith "artifacts/" || (artPath.splitOn "..").length > 1 then
        return some (jsonErr 400 "Invalid artifact path")
      let turns := (execJv.fieldArr? "turns").getD #[]
      let matched := turns.any (fun t =>
        ((t.fieldArr? "artifacts").getD #[]).any (fun a => (a.fieldStr? "path") == some artPath))
      if !matched then
        return some (jsonErr 404 "Artifact not found on cloud mission")
      let agentId := (execJv.fieldStr? "external_id").getD ""
      if agentId.isEmpty then
        return some (jsonErr 400 "Missing external agent ID")
      let cursorKey ← getEnvTrimmed "CURSOR_CLOUD_API_KEY"
      let basicHdr := #[("Authorization", "Basic " ++ base64Encode s!"{cursorKey}:".toUTF8 false true)]
      match ← sendJsonRequest "GET"
          s!"https://api.cursor.com/v1/agents/{urlEncodeComponent agentId}/artifacts/download?path={urlEncodeComponent artPath}"
          none none basicHdr 15000 4194304 with
      | .ok (c, _, some aj) =>
        if 200 ≤ c && c < 300 then return some (jsonResp 200 aj)
        else return some (jsonErr 502 "Upstream artifact download failed")
      | _ => return some (jsonErr 502 "Upstream artifact download failed")

    if method == "GET" && segs.length == 6 && segs[5]? == some "children" then
      let prov := (((execJv.field? "selection").getD (.obj #[])).fieldStr? "provider").getD ""
      if prov != "hermes" then
        return some (jsonErr 404 "Hermes mission not found")
      let mut sessIds : Array String := #[]
      if let some ext := execJv.fieldStr? "external_id" then
        if !ext.isEmpty then sessIds := sessIds.push ext
      for t in ((execJv.fieldArr? "turns").getD #[]) do
        if let some sid := t.fieldStr? "session_id" then
          if !sid.isEmpty && !sessIds.contains sid then sessIds := sessIds.push sid
      let mut childMissions : Array JVal := #[]
      let mut seenMids : Array String := #[]
      for sid in sessIds do
        if let .ok crows ← execParamQuery store.missionsDb
            "SELECT id, title, status FROM missions WHERE origin_session_id=?1 OR parent_mission_id=?2 ORDER BY created_at ASC LIMIT 200;"
            #[sid, mid] then
          for i in [1:crows.size] do
            let cid := (crows[i]![0]?).getD ""
            let ctitle := (crows[i]![1]?).getD ""
            let cst := (crows[i]![2]?).getD "active"
            if !cid.isEmpty && cid != mid && !seenMids.contains cid then
              seenMids := seenMids.push cid
              childMissions := childMissions.push (.obj #[
                ("id", .str cid),
                ("title", if ctitle.isEmpty then .null else .str ctitle),
                ("status", .str cst)
              ])
      return some (jsonResp 200 (.obj #[("missions", .arr childMissions)]))

    if method == "POST" && segs.length == 6 && segs[5]? == some "approval" then
      let wrAllowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped true
      if !wrAllowed then
        return some (jsonErr 403 "Write access required")
      let prov := (((execJv.field? "selection").getD (.obj #[])).fieldStr? "provider").getD ""
      if prov != "hermes" then
        return some (jsonErr 404 "Hermes mission not found")
      let .ok reqJv := OrbBin.Json.parseBytes bodyBytes
        | return some (jsonErr 400 "Invalid JSON body")
      let runId := ((reqJv.fieldStr? "run_id").getD "").trimAscii.toString
      let reqId := ((reqJv.fieldStr? "request_id").getD "").trimAscii.toString
      let choice := ((reqJv.fieldStr? "choice").getD "").trimAscii.toString
      if runId.isEmpty || reqId.isEmpty || choice.isEmpty then
        return some (jsonErr 400 "run_id, request_id, and choice are required")
      if !isSafeHermesRunId runId then
        return some (jsonErr 400 "Invalid Hermes run identity")
      let turns := (execJv.fieldArr? "turns").getD #[]
      let validTurn := turns.any (fun t =>
        (t.fieldStr? "external_id") == some runId &&
        (t.fieldStr? "phase") == some "waiting_user" &&
        ((t.fieldArr? "artifacts").getD #[]).any (fun a =>
          (a.fieldStr? "kind") == some "hermes_approval" &&
          match a.field? "request" with
          | some r =>
            let rIdMatch := (r.fieldStr? "request_id") == some reqId ||
              ((r.fieldNat? "request_id").map toString) == some reqId
            let choicesArr := (r.fieldArr? "choices").getD #[]
            let choiceOk := choicesArr.isEmpty || choicesArr.any (fun c => c.asStr? == some choice)
            rIdMatch && choiceOk
          | none => false))
      if !validTurn then
        return some (jsonErr 409 "Approval no longer belongs to the active turn")
      let (_, hermesUrl, apiKey?, _, _) ← resolveEffectiveHermesEndpoint serverPort
      let some apiKey := apiKey?
        | return some (jsonErr 502 "Hermes API server key is not configured")
      match ← sendJsonRequest "POST"
          s!"{hermesUrl}/v1/runs/{urlEncodeComponent runId}/approval"
          (some apiKey) (some (.obj #[("choice", .str choice), ("request_id", .str reqId)])) #[] 10000 262144 with
      | .ok (c, _, some rj) =>
        if 200 ≤ c && c < 300 then
          ensureCloudMissionWorker hub store broadcastHub? serverPort mid
          return some (jsonResp 200 rj)
        else
          return some (jsonErr 502 "Hermes approval request failed")
      | _ => return some (jsonErr 502 "Hermes approval request failed")

    if method == "POST" && segs.length == 6 && segs[5]? == some "cancel" then
      let wrAllowed ← canAccessMission store mid callerUserId bootstrapAdminId isLegacyUnscoped true
      if !wrAllowed then
        return some (jsonErr 403 "Write access required")
      let turns := (execJv.fieldArr? "turns").getD #[]
      let some idx := turns.findIdx? (fun t => !isPhaseTerminal ((t.fieldStr? "phase").getD "response_complete"))
        | return some (jsonErr 400 "No active run")
      let t := turns[idx]!
      let ph := (t.fieldStr? "phase").getD "queued"
      if ph == "cancel_requested" then
        ensureCloudMissionWorker hub store broadcastHub? serverPort mid
        return some (jsonResp 200 (.obj #[("cancel_requested", .bool true)]))
      let extId := (t.fieldStr? "external_id").getD ""
      if ph != "queued" && extId.isEmpty then
        return some (jsonErr 400 "Reconcile the submission before cancelling")
      let nextPh := if ph == "queued" then "cancelled" else "cancel_requested"
      let nextTurns := turns.set! idx (t.setField "phase" (.str nextPh))
      let prov := (((execJv.field? "selection").getD (.obj #[])).fieldStr? "provider").getD "hermes"
      let reqKey := (execJv.fieldStr? "request_key").getD mid
      if let .error e ← saveCloudExecutionCas store broadcastHub? mid reqKey prov (some rev) (execJv.setField "turns" (.arr nextTurns)) then
        return some (jsonErr 409 s!"Cancel conflict: {e}")
      if nextPh == "cancel_requested" then
        ensureCloudMissionWorker hub store broadcastHub? serverPort mid
      return some (jsonResp 200 (.obj #[("cancel_requested", .bool true)]))

  return none

end OrbCore.CloudHttpAndWorker
