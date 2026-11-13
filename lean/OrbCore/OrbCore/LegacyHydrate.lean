/-
  OrbCore.LegacyHydrate: Production Upgrade & Wire Compatibility Layer (`0 import Lean`, `0 sorryAx`).
  - `<encrypted v="1">BASE64(nonce12 || ctTag16)</encrypted>` AES-256-GCM env/secret crypto (`OrbNetLeaf.Crypto`)
  - RFC 7519 HS256 JWT (`eyJ...`) minting & constant-time verification for seamless session continuity
  - `.sandboxed-sh/proxy_api_keys.json` SHA-256 proxy key verification & CRUD
  - `.sandboxed-sh/settings.json` & non-destructive startup hydration of legacy JSON state
    (`ai_providers.json`, `model_chains.json`, `workspaces.json`, `managed_machines.json`,
     `managed_machine_secrets.json`, `mission_budgets.json`, `project-files/<slug>/`) into SQLite
  - `BroadcastHub` for SSE control/mission streams (`/api/control/stream`, `/api/control/missions/:id/stream`)
-/
import Std.Sync.Mutex
import LeanSys
import OrbBin.Json
import OrbBin.PosixExt
import OrbNetLeaf.Crypto
import OrbCore.Store
import OrbCore.Managed
import OrbCore.R7Core

namespace OrbCore.LegacyHydrate

open LeanSys.Auth
open LeanSys.Posix
open OrbBin.Json
open OrbBin.PosixExt
open OrbNetLeaf.Crypto
open OrbCore.Store
open OrbCore.Managed
open OrbCore.R7Core

def encryptedPrefix : String := "<encrypted v=\"1\">"
def encryptedSuffix : String := "</encrypted>"

def isEncryptedValue (s : String) : Bool :=
  let t := s.trimAscii.toString
  t.startsWith encryptedPrefix && t.endsWith encryptedSuffix

private def hexNibble? (c : Char) : Option UInt8 :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat).toUInt8
  else if 'a' ≤ c && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat).toUInt8
  else if 'A' ≤ c && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat).toUInt8
  else none

def hexDecodeExact? (s : String) : Option ByteArray := Id.run do
  let cs := s.trimAscii.toString.toList.toArray
  if cs.size % 2 != 0 || cs.isEmpty then return none
  let mut out := ByteArray.emptyWithCapacity (cs.size / 2)
  let mut i : Nat := 0
  while i + 1 < cs.size do
    match hexNibble? cs[i]!, hexNibble? cs[i + 1]! with
    | some hi, some lo =>
      out := out.push ((hi <<< 4) ||| lo)
      i := i + 2
    | _, _ => return none
  return some out

/-- Parse a 32-byte AES-256-GCM key from 64 hex chars or Base64 (`PRIVATE_KEY` / `.sandboxed-sh/private_key`). -/
def parsePrivateKeyBytes? (raw : String) : Option ByteArray :=
  let trimmed := raw.trimAscii.toString
  if trimmed.isEmpty then none
  else
    match hexDecodeExact? trimmed with
    | some b => if b.size == 32 then some b else none
    | none =>
      match base64Decode? trimmed with
      | some b => if b.size == 32 then some b else none
      | none => none

/-- Discover existing 32-byte `private_key` from `PRIVATE_KEY`, `PRIVATE_KEY_FILE`, or `{dataRoot}/private_key`. -/
def loadPrivateKeyBytes? (workingDir dataRoot : String) : IO (Option ByteArray) := do
  if let some envKey ← getEnvNonEmpty "PRIVATE_KEY" then
    if let some k := parsePrivateKeyBytes? envKey then
      return some k
  if let some keyFile ← getEnvNonEmpty "PRIVATE_KEY_FILE" then
    if let some raw ← (try some <$> IO.FS.readFile keyFile catch _ => pure none) then
      if let some k := parsePrivateKeyBytes? raw then
        return some k
  let cands : Array String := #[
    s!"{dataRoot}/private_key",
    s!"{workingDir}/.sandboxed-sh/private_key"
  ]
  for p in cands do
    if (← System.FilePath.pathExists p) then
      if let some raw ← (try some <$> IO.FS.readFile p catch _ => pure none) then
        if let some k := parsePrivateKeyBytes? raw then
          return some k
  return none

/-- Load or atomically generate `{dataRoot}/private_key` (`0600`, 64 lowercase hex chars = 32 bytes). -/
def loadOrCreatePrivateKeyBytes (workingDir dataRoot : String) : IO (Except String ByteArray) := do
  if let some existing ← loadPrivateKeyBytes? workingDir dataRoot then
    return .ok existing
  let .ok rnd ← randBytes 32
    | return .error "failed to generate 32-byte private_key"
  let hexStr := bytesToHexLower rnd ++ "\n"
  let keyPath := System.FilePath.mk s!"{dataRoot}/private_key"
  if let .error e ← writeAtomicPrivate0600 keyPath hexStr.toUTF8 then
    return .error e
  return .ok rnd

/-- Encrypt plaintext as `<encrypted v="1">BASE64(nonce12 || ctTag16)</encrypted>` with empty AAD. -/
def encryptEnvValue (key32 : ByteArray) (plaintext : String) : IO (Except String String) := do
  if isEncryptedValue plaintext then
    return .ok plaintext
  if key32.size != 32 then
    return .error "invalid 32-byte key"
  let .ok nonce12 ← randBytes 12
    | return .error "failed to generate 12-byte GCM nonce"
  match ← aeadSeal .aes256Gcm key32 nonce12 ByteArray.empty plaintext.toUTF8 with
  | .error e => return .error e
  | .ok ctTag =>
    let combined := nonce12 ++ ctTag
    let b64 := base64Encode combined (urlSafe := false) (pad := true)
    return .ok s!"{encryptedPrefix}{b64}{encryptedSuffix}"

/-- Decrypt `<encrypted v="1">BASE64(nonce12 || ctTag16)</encrypted>`, passing plaintext strings through unchanged. -/
def decryptEnvValue (key32? : Option ByteArray) (raw : String) : IO (Except String String) := do
  let t := raw.trimAscii.toString
  if !isEncryptedValue t then
    return .ok raw
  let some key32 := key32?
    | return .error "missing private_key for encrypted value"
  if key32.size != 32 then
    return .error "invalid private_key length"
  let inner := ((t.drop encryptedPrefix.length).dropEnd encryptedSuffix.length).toString.trimAscii.toString
  let some combined := base64Decode? inner
    | return .error "invalid base64 inside <encrypted>"
  if combined.size < 28 then
    return .error "ciphertext too short inside <encrypted>"
  let nonce12 := combined.extract 0 12
  let ctTag := combined.extract 12 combined.size
  match ← aeadOpen .aes256Gcm key32 nonce12 ByteArray.empty ctTag with
  | .error e => return .error e
  | .ok ptBytes =>
    match String.fromUTF8? ptBytes with
    | some s => return .ok s
    | none => return .error "decrypted value is not valid UTF-8"

/-- Recursively decrypt any `<encrypted v="1">...</encrypted>` string leaves inside a `JVal` tree. -/
partial def decryptJsonTree (key32? : Option ByteArray) (v : JVal) : IO JVal := do
  match v with
  | .str s =>
    if isEncryptedValue s then
      match ← decryptEnvValue key32? s with
      | .ok plain => return .str plain
      | .error _ => return .str ""
    else
      return .str s
  | .arr xs =>
    let mut out : Array JVal := Array.mkEmpty xs.size
    for x in xs do
      out := out.push (← decryptJsonTree key32? x)
    return .arr out
  | .obj kvs =>
    let mut out : Array (String × JVal) := Array.mkEmpty kvs.size
    for (k, fv) in kvs do
      out := out.push (k, ← decryptJsonTree key32? fv)
    return .obj out
  | other => return other

/-! ## RFC 7519 HS256 JWT (`eyJ...`) -/

/-- Mint an RFC 7519 HS256 JWT (`{"alg":"HS256","typ":"JWT"}.{"sub":...,"usr":...,"iat":...,"exp":...}.sig`). -/
def issueHs256Jwt (secret userId username : String) (iatSec expSec : UInt64) (role : String := "admin") : String :=
  let hdrJson := "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
  let payJson := renderCompact (.obj #[
    ("sub", .str userId),
    ("usr", .str username),
    ("role", .str role),
    ("iat", JVal.uint64 iatSec),
    ("exp", JVal.uint64 expSec)
  ])
  let hdrB64 := base64Encode hdrJson.toUTF8 (urlSafe := true) (pad := false)
  let payB64 := base64Encode payJson.toUTF8 (urlSafe := true) (pad := false)
  let signingInput := s!"{hdrB64}.{payB64}"
  let mac := hmacSha256Bytes secret.toUTF8 signingInput.toUTF8
  let sigB64 := base64Encode mac (urlSafe := true) (pad := false)
  s!"{signingInput}.{sigB64}"

/-- Verify an RFC 7519 HS256 JWT (`eyJ...`), returning `(sub, usr, expEpochSec)`. -/
def verifyHs256Jwt? (secret token : String) (nowEpochSec : UInt64) : Option (String × String × UInt64) := do
  if secret.isEmpty || !token.startsWith "eyJ" then none
  else
    match token.splitOn "." with
    | [hdrB64, payB64, sigB64] => do
      let hdrBytes ← base64Decode? hdrB64
      let hdrStr ← String.fromUTF8? hdrBytes
      let hdrJv ← (OrbBin.Json.parse hdrStr).toOption
      let alg ← hdrJv.fieldStr? "alg"
      if alg != "HS256" then none
      else do
        let signingInput := s!"{hdrB64}.{payB64}"
        let expectedMac := hmacSha256Bytes secret.toUTF8 signingInput.toUTF8
        let expectedSig := base64Encode expectedMac (urlSafe := true) (pad := false)
        if !ctEqString sigB64 expectedSig then none
        else do
          let payBytes ← base64Decode? payB64
          let payStr ← String.fromUTF8? payBytes
          let payJv ← (OrbBin.Json.parse payStr).toOption
          let exp ← payJv.fieldUInt64? "exp"
          if nowEpochSec ≥ exp then none
          else
            let sub := (payJv.fieldStr? "sub").getD "default"
            let usr := (payJv.fieldStr? "usr").getD "admin"
            some (sub, usr, exp)
    | _ => none

/-! ## Single-Tenant User ID & `.sandboxed-sh/settings.json` -/

def configuredSingleTenantUserId (devMode : Bool) : IO String := do
  match ← firstEnvNonEmpty ["SANDBOXED_SINGLE_TENANT_USER_ID", "SINGLE_TENANT_USER_ID"] with
  | some uid => return uid.trimAscii.toString
  | none => return if devMode then "dev" else "default"

def settingsFilePath (dataRoot : String) : System.FilePath :=
  System.FilePath.mk s!"{dataRoot}/settings.json"

def readSettingsJson (dataRoot : String) : IO JVal := do
  let p := settingsFilePath dataRoot
  if !(← p.pathExists) then
    return .obj #[]
  match ← (try some <$> IO.FS.readFile p catch _ => pure none) with
  | none => return .obj #[]
  | some raw =>
    match OrbBin.Json.parse raw with
    | .ok v@(.obj _) => return v
    | _ => return .obj #[]

def writeSettingsJson (dataRoot : String) (jv : JVal) : IO (Except String Unit) :=
  writeAtomicPrivate0600 (settingsFilePath dataRoot) ((renderPretty jv) ++ "\n").toUTF8

/-- Check `dashboard_password_hash` inside `.sandboxed-sh/settings.json` (`pbkdf2:...` or `pbkdf2-sha256$...`). -/
def verifySettingsPasswordHash (dataRoot suppliedPassword : String) : IO Bool := do
  if suppliedPassword.isEmpty then return false
  let settings ← readSettingsJson dataRoot
  match settings.fieldStr? "dashboard_password_hash" with
  | none => return false
  | some h =>
    if h.trimAscii.isEmpty then return false
    verifyPasswordPbkdf2 suppliedPassword h.trimAscii.toString

/-! ## `.sandboxed-sh/proxy_api_keys.json` -/

def proxyKeysFilePath (dataRoot : String) : System.FilePath :=
  System.FilePath.mk s!"{dataRoot}/proxy_api_keys.json"

private def loadRawProxyKeys (dataRoot : String) : IO (Array JVal) := do
  let p := proxyKeysFilePath dataRoot
  if !(← p.pathExists) then return #[]
  match ← (try some <$> IO.FS.readFile p catch _ => pure none) with
  | none => return #[]
  | some raw =>
    match OrbBin.Json.parse raw with
    | .ok (.arr xs) => return xs
    | .ok v@(.obj _) => return (v.fieldArr? "keys").getD #[]
    | _ => return #[]

private def saveRawProxyKeys (dataRoot : String) (xs : Array JVal) : IO (Except String Unit) :=
  writeAtomicPrivate0600 (proxyKeysFilePath dataRoot) ((renderPretty (.arr xs)) ++ "\n").toUTF8

/-- Constant-time SHA-256 verification against `.sandboxed-sh/proxy_api_keys.json`. -/
def verifyProxyApiKeyFile (dataRoot rawKey : String) (nowIso : String := "") : IO Bool := do
  let clean := rawKey.trimAscii.toString
  if clean.isEmpty then return false
  let items ← loadRawProxyKeys dataRoot
  if items.isEmpty then return false
  let candHash := bytesToHexLower (sha256Bytes clean.toUTF8)
  let mut matchedIdx? : Option Nat := none
  for i in [0:items.size] do
    let kh := ((items[i]!.fieldStr? "key_hash").getD "").trimAscii.toString.toLower
    if !kh.isEmpty && ctEqString candHash kh then
      matchedIdx? := some i
  match matchedIdx? with
  | none => return false
  | some idx =>
    if !nowIso.isEmpty then
      let updated := items.mapIdx fun i it =>
        if i == idx then it.setField "last_used_at" (.str nowIso) else it
      discard <| saveRawProxyKeys dataRoot updated
    return true

def listProxyApiKeysJson (dataRoot : String) : IO String := do
  let items ← loadRawProxyKeys dataRoot
  let redacted := items.map fun it =>
    .obj #[
      ("id", .str ((it.fieldStr? "id").getD "")),
      ("name", .str ((it.fieldStr? "name").getD "API Key")),
      ("key_prefix", .str ((it.fieldStr? "key_prefix").getD "sk-orb-...")),
      ("created_at", .str ((it.fieldStr? "created_at").getD "")),
      ("last_used_at", it.fieldOrNull "last_used_at")
    ]
  return renderCompact (.obj #[("keys", .arr redacted)])

def createProxyApiKeyJson (dataRoot name nowIso : String) : IO (Except String String) := do
  let id ← newUuidV4
  let .ok rnd ← randBytes 24
    | return .error "csprng_failed"
  let rawKey := "sk-orb-" ++ bytesToHexLower rnd
  let keyHash := bytesToHexLower (sha256Bytes rawKey.toUTF8)
  let prefixStr := (rawKey.take 13).toString ++ "..."
  let cleanName := let t := name.trimAscii.toString; if t.isEmpty then "API Key" else t
  let items ← loadRawProxyKeys dataRoot
  let entry := JVal.obj #[
    ("id", .str id),
    ("name", .str cleanName),
    ("key_hash", .str keyHash),
    ("key_prefix", .str prefixStr),
    ("created_at", .str nowIso),
    ("last_used_at", .null)
  ]
  if let .error e ← saveRawProxyKeys dataRoot (items.push entry) then
    return .error e
  return .ok (renderCompact (.obj #[
    ("id", .str id),
    ("name", .str cleanName),
    ("key", .str rawKey),
    ("key_prefix", .str prefixStr),
    ("created_at", .str nowIso)
  ]))

def deleteProxyApiKey (dataRoot keyId : String) : IO Bool := do
  let items ← loadRawProxyKeys dataRoot
  let kept := items.filter (fun it => (it.fieldStr? "id").getD "" != keyId)
  if kept.size == items.size then return false
  match ← saveRawProxyKeys dataRoot kept with
  | .ok () => return true
  | .error _ => return false

/-! ## SSE Broadcast Hub (`GET /api/control/stream`, `GET /api/control/missions/:id/stream`) -/

structure SseSubscriber where
  id             : UInt64
  missionFilter? : Option String
  queueRef       : IO.Ref (Array String)

structure BroadcastHub where
  mu : Std.Mutex (UInt64 × Array SseSubscriber)

def newBroadcastHub : IO BroadcastHub := do
  let mu ← Std.Mutex.new ((0 : UInt64), (#[] : Array SseSubscriber))
  return { mu }

def formatSseFrame (eventType payloadJson : String) (seqId? : Option UInt64 := none) : String :=
  let idLine := match seqId? with | some n => s!"id: {n}\n" | none => ""
  let safeType := ((eventType.splitOn "\n").headD "message").trimAscii.toString
  let dataLines := String.intercalate "\n" ((payloadJson.splitOn "\n").map (fun l => s!"data: {l}"))
  s!"{idLine}event: {safeType}\n{dataLines}\n\n"

def publishControlEvent
    (hub? : Option BroadcastHub)
    (eventType payloadJson : String)
    (missionId? : Option String := none) : IO Unit := do
  let some hub := hub? | return ()
  let subs ← hub.mu.atomically do
    let (seq, xs) ← get
    let nextSeq := seq + 1
    set (nextSeq, xs)
    return (nextSeq, xs)
  let frame := formatSseFrame eventType payloadJson (some subs.1)
  for sub in subs.2 do
    let matchesMission :=
      match sub.missionFilter?, missionId? with
      | none, _ => true
      | some want, some got => want == got
      | some _, none => false
    if matchesMission then
      sub.queueRef.modify fun q =>
        let base := if q.size ≥ 256 then q.extract 1 q.size else q
        base.push frame

def registerSseSubscriber (hub : BroadcastHub) (missionFilter? : Option String) : IO (UInt64 × IO.Ref (Array String)) := do
  let qRef ← IO.mkRef (#[] : Array String)
  let subId ← hub.mu.atomically do
    let (seq, xs) ← get
    let sid := seq + 1
    set (sid, xs.push { id := sid, missionFilter? := missionFilter?, queueRef := qRef })
    return sid
  return (subId, qRef)

def unregisterSseSubscriber (hub : BroadcastHub) (subId : UInt64) : IO Unit := do
  hub.mu.atomically do
    let (seq, xs) ← get
    set (seq, xs.filter (fun s => s.id != subId))

/-! ## Non-Destructive Legacy `.sandboxed-sh/` Hydration -/

private def hydrateProjectFilesTree
    (st : CoreStore) (projectFilesRoot : System.FilePath) (slug : String) (_nowIso : String) : IO Unit := do
  let projDir := projectFilesRoot / slug
  if !(← projDir.pathExists) then return ()
  let mut stack : Array (System.FilePath × String) := #[(projDir, "")]
  let mut visited : Nat := 0
  while !stack.isEmpty && visited < 2000 do
    let (curFs, relPrefix) := stack.back!
    stack := stack.pop
    visited := visited + 1
    let entries ← (try curFs.readDir catch _ => pure #[])
    for ent in entries do
      let name := ent.fileName
      if !name.isEmpty && !name.startsWith "." then
        let relPath := if relPrefix.isEmpty then name else s!"{relPrefix}/{name}"
        let pStat ← statPath ent.path.toString
        if !pStat.isSymlink then
          if pStat.isDir then
            discard <| execParamQuery st.projectsDb
              ("INSERT OR IGNORE INTO context_entries(project_slug,path,content_hash,directory,revision,size,deleted,source) " ++
               "VALUES(?1,?2,'',1,1,0,0,'legacy');")
              #[slug, relPath]
            stack := stack.push (ent.path, relPath)
          else if pStat.isReg then
            let iden ← statIdentity ent.path.toString false
            -- Store empty hash marker if not yet in CAS; `/api/projects/:slug/file` falls back to `project-files/<slug>/<path>`!
            discard <| execParamQuery st.projectsDb
              ("INSERT OR IGNORE INTO context_entries(project_slug,path,content_hash,directory,revision,size,deleted,source) " ++
               "VALUES(?1,?2,'',0,1,CAST(?3 AS INTEGER),0,'legacy');")
              #[slug, relPath, s!"{iden.size}"]
  discard <| execParamQuery st.projectsDb
    ("INSERT OR IGNORE INTO context_heads(project_slug,revision) VALUES(?1,1);")
    #[slug]

/-- Non-destructively hydrate `.sandboxed-sh/*.json` & `project-files/` into SQLite on startup. -/
def hydrateLegacyDataDir
    (workingDir dataRoot : String)
    (st : CoreStore)
    (mg : ManagedComputeStore)
    (bootAdminId : String)
    (_devMode : Bool := false) : IO Unit := do
  let nowSec ← coreEpochSec
  let nowIso := formatEpochIso8601Utc nowSec
  let key32? ← loadPrivateKeyBytes? workingDir dataRoot
  let settings ← readSettingsJson dataRoot

  -- 1. Single-tenant `settings.json` password hash continuity (legacy JWT `sub` maps via `getBootstrapAdmin?`)
  if let some settingsHash := (settings.fieldStr? "dashboard_password_hash").filter (!·.trimAscii.isEmpty) then
    if !bootAdminId.isEmpty then
      discard <| execParamQuery st.missionsDb
        "UPDATE users SET password_hash=?2 WHERE id=?1 AND (password_hash='' OR password_hash LIKE '%placeholder%');"
        #[bootAdminId, settingsHash.trimAscii.toString]

  -- 2. Hydrate `ai_providers.json` -> `ai_providers`
  let aiProvPath := System.FilePath.mk s!"{dataRoot}/ai_providers.json"
  if (← aiProvPath.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile aiProvPath catch _ => pure none) then
      if let .ok parsed := OrbBin.Json.parse raw then
        let dec ← decryptJsonTree key32? parsed
        let arr := match dec with
          | .arr xs => xs
          | .obj _ => (dec.fieldArr? "providers").getD #[]
          | _ => #[]
        for p in arr do
          let pid := ((p.fieldStr? "id").getD "").trimAscii.toString
          if !pid.isEmpty then
            if (← getAIProvider? st pid).isNone then
              let pType := ((p.fieldStr? "provider_type").getD "custom").trimAscii.toString
              let nm := ((p.fieldStr? "name").getD pType).trimAscii.toString
              let en := (p.fieldBool? "enabled").getD true
              let bUrl := ((p.fieldStr? "base_url").getD "").trimAscii.toString
              let aKey := ((p.fieldStr? "api_key").getD "").trimAscii.toString
              let rpm? := (p.fieldNat? "rpm_limit").map Nat.toUInt32
              let conc? := (p.fieldNat? "max_concurrency").map Nat.toUInt32
              let cModels :=
                match p.fieldArr? "custom_models" with
                | some cms =>
                  cms.filterMap fun cm =>
                    let mid := ((cm.fieldStr? "id").getD "").trimAscii.toString
                    if mid.isEmpty then none
                    else some {
                      id := mid
                      name? := cm.fieldStr? "name"
                      contextLimit? := (cm.fieldNat? "context_limit").map Nat.toUInt32
                      outputLimit? := (cm.fieldNat? "output_limit").map Nat.toUInt32
                      rpmLimit? := (cm.fieldNat? "rpm_limit").map Nat.toUInt32
                      tpmLimit? := (cm.fieldNat? "tpm_limit").map Nat.toUInt64
                      maxConcurrency? := (cm.fieldNat? "max_concurrency").map Nat.toUInt32
                    }
                | none => #[]
              discard <| upsertAIProvider st {
                id := pid, providerType := pType, name := nm, enabled := en,
                baseUrl := bUrl, apiKey := aKey, rpmLimit? := rpm?, maxConcurrency? := conc?,
                customModels := cModels, updatedAt := nowIso
              }

  -- 3. Hydrate `model_chains.json` / `routing_chains.json` -> `model_routing_chains`
  for chainFile in #["model_chains.json", "routing_chains.json", "model_routing.json"] do
    let cp := System.FilePath.mk s!"{dataRoot}/{chainFile}"
    if (← cp.pathExists) then
      if let some raw ← (try some <$> IO.FS.readFile cp catch _ => pure none) then
        if let .ok jv := OrbBin.Json.parse raw then
          let dec ← decryptJsonTree key32? jv
          let arr := match dec with
            | .arr xs => xs
            | .obj _ => (dec.fieldArr? "chains").getD #[]
            | _ => #[]
          for c in arr do
            let cid := ((c.fieldStr? "id").getD "").trimAscii.toString
            if !cid.isEmpty then
              let nm := ((c.fieldStr? "name").getD cid).trimAscii.toString
              let mj :=
                match (c.field? "entries").orElse (fun _ => c.field? "models") with
                | some a@(.arr _) => renderCompact a
                | _ => (c.fieldStr? "models_json").getD "[]"
              discard <| execParamQuery st.missionsDb
                "INSERT OR IGNORE INTO model_routing_chains(id,name,models_json,updated_at) VALUES(?1,?2,?3,?4);"
                #[cid, nm, mj, nowIso]
              -- Rust also persisted these three fields; import them once (NULL = not yet imported).
              discard <| execParamQuery st.missionsDb
                "UPDATE model_routing_chains SET is_default=CAST(?2 AS INTEGER), strip_thinking=CAST(?3 AS INTEGER), created_at=COALESCE(NULLIF(?4,''),created_at) WHERE id=?1 AND is_default IS NULL;"
                #[cid, if (c.fieldBool? "is_default").getD false then "1" else "0",
                  if (c.fieldBool? "strip_thinking").getD false then "1" else "0", (c.fieldStr? "created_at").getD ""]

  -- 4. Hydrate `workspaces.json` -> `workspaces`
  let wsPath := System.FilePath.mk s!"{dataRoot}/workspaces.json"
  if (← wsPath.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile wsPath catch _ => pure none) then
      if let .ok jv := OrbBin.Json.parse raw then
        let arr := match jv with
          | .arr xs => xs
          | .obj kvs =>
            match jv.fieldArr? "workspaces" with
            | some xs => xs
            | none => kvs.map Prod.snd
          | _ => #[]
        for w in arr do
          let wid := ((w.fieldStr? "id").getD "").trimAscii.toString
          let wpath := ((w.fieldStr? "path").getD "").trimAscii.toString
          if !wid.isEmpty && !wpath.isEmpty then
            let wname := ((w.fieldStr? "name").getD wid).trimAscii.toString
            let wtype := ((w.fieldStr? "workspace_type").getD "host").trimAscii.toString
            let cat := ((w.fieldStr? "created_at").getD nowIso).trimAscii.toString
            let ownerUid := bootAdminId
            discard <| execParamQuery st.missionsDb
              "INSERT OR IGNORE INTO workspaces(id,name,path,workspace_type,owner_user_id,created_at) VALUES(?1,?2,?3,?4,?5,?6);"
              #[wid, wname, wpath, wtype, ownerUid, cat]

  -- 5. Hydrate `managed_compute` settings + Boat API key + `managed_machines.json` + `managed_machine_secrets.json` + `mission_budgets.json`
  let mcObj := (settings.field? "managed_compute").getD (.obj #[])
  let boatEnvKey? ← firstEnvNonEmpty ["BOAT_API_KEY", "SANDBOXED_BOAT_API_KEY"]
  let boatSettingsKey? ← do
    match mcObj.fieldStr? "boat_api_key" with
    | none => pure none
    | some rawK =>
      match ← decryptEnvValue key32? rawK with
      | .ok k => pure (if k.trimAscii.isEmpty then none else some k.trimAscii.toString)
      | .error _ => pure none
  if let some bk := boatEnvKey?.orElse (fun _ => boatSettingsKey?) then
    discard <| sealProviderSecret dataRoot "boat" bk

  let fleetRows ← execParamQuery mg.db "SELECT COUNT(*) FROM managed_fleet_state;" #[]
  let hasFleetRow := match fleetRows with | .ok rs => (((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0) > 0 | .error _ => false
  if !hasFleetRow then
    let mcEnabled := (mcObj.fieldBool? "enabled").getD (boatEnvKey?.isSome || boatSettingsKey?.isSome)
    let boatEnabled := (mcObj.fieldBool? "boat_enabled").getD mcEnabled
    let capCents : UInt64 :=
      match mcObj.fieldUInt64? "daily_cap_cents" with
      | some c => c
      | none =>
        match parseDeciMilliUsd? (mcObj.fieldOrNull "daily_cap_usd") 0 1000000000 with
        | some dm => dm / 100
        | none => 5000
    let maxConc : UInt64 := (mcObj.fieldUInt64? "max_concurrent").getD 100
    discard <| saveManagedFleetConfig mg mcEnabled boatEnabled capCents 0 maxConc

  let mut secretsObj : Array (String × JVal) := #[]
  let mmSecPath := System.FilePath.mk s!"{dataRoot}/managed_machine_secrets.json"
  if (← mmSecPath.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile mmSecPath catch _ => pure none) then
      if let .ok jv := OrbBin.Json.parse raw then
        let dec ← decryptJsonTree key32? jv
        let unwrapped := (dec.field? "machines").getD dec
        if let .obj kvs := unwrapped then
          secretsObj := kvs

  let mmPath := System.FilePath.mk s!"{dataRoot}/managed_machines.json"
  if (← mmPath.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile mmPath catch _ => pure none) then
      if let .ok jv := OrbBin.Json.parse raw then
        let arr := match jv with
          | .arr xs => xs
          | .obj kvs =>
            match jv.fieldArr? "machines" with
            | some xs => xs
            | none => kvs.map Prod.snd
          | _ => #[]
        for m in arr do
          let mid := ((m.fieldStr? "id").getD "").trimAscii.toString
          if !mid.isEmpty then
            let sbox := ((m.fieldStr? "sandbox_name").orElse (fun _ => m.fieldStr? "name") |>.getD mid).trimAscii.toString
            let prov := canonicalizeProvider ((m.fieldStr? "provider").getD "boat")
            let sz := ((m.fieldStr? "size").getD "small").trimAscii.toString
            let rawSt := (((m.fieldStr? "state").orElse (fun _ => m.fieldStr? "status")).getD "ready").trimAscii.toString.toLower
            let (normStatus, phaseCode) : String × UInt8 :=
              if rawSt == "ready" || rawSt == "online" || rawSt == "running" then ("ready", 1)
              else if rawSt == "stopped" || rawSt == "stopped_in_place" then ("stopped", 2)
              else if rawSt == "destroyed" || rawSt == "failed" || rawSt == "deleted" then ("destroyed", 3)
              else ("provisioning", 0)
            let ownerMid := ((m.fieldStr? "owner_mission_id").orElse (fun _ => m.fieldStr? "owner_mission") |>.getD "").trimAscii.toString
            let reqByMid := ((m.fieldStr? "requested_by_mission_id").getD ownerMid).trimAscii.toString
            let ttlMins := (m.fieldUInt64? "ttl_minutes").getD 60
            let spentCents := (m.fieldUInt64? "spent_cents").getD 0
            let cord := (m.fieldBool? "cordoned").getD false
            let elig : UInt8 := if phaseCode == 1 && !cord then 1 else 0
            let ownerUid := ((m.fieldStr? "owner_user_id").filter (!·.isEmpty)).getD bootAdminId
            discard <| execParamQuery mg.db
              ("INSERT OR IGNORE INTO managed_machines(" ++
               "id,sandbox_name,provider,size,status,owner_mission,ttl_minutes,spent_cents,cordoned," ++
               "node_boot_epoch,deletable_at_sec,owner_kind,requested_by_mission_id,phase_code,active_compute_eligible,owner_user_id) " ++
               "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,1,0,'mission',?10,?11,?12,?13);")
              #[mid, sbox, prov, sz, normStatus, ownerMid, s!"{ttlMins}", s!"{spentCents}",
                if cord then "1" else "0", reqByMid, s!"{phaseCode}", s!"{elig}", ownerUid]
            let secEntry? := (secretsObj.find? (fun (k, _) => k == mid)).map Prod.snd
            let inlineTok? ← do
              match m.fieldStr? "node_token" with
              | none => pure none
              | some t =>
                match ← decryptEnvValue key32? t with
                | .ok dt => pure (if dt.isEmpty then none else some dt)
                | .error _ => pure none
            let nodeTok := ((secEntry?.bind (·.fieldStr? "node_token")).orElse (fun _ => inlineTok?)).getD ""
            let enrollTok := (secEntry?.bind (·.fieldStr? "enroll_token")).getD ""
            let nodeId := ((m.fieldStr? "node_id").filter (!·.isEmpty)).getD s!"managed-{mid}"
            if !nodeTok.isEmpty || !enrollTok.isEmpty then
              discard <| execParamQuery mg.db
                ("INSERT OR IGNORE INTO managed_node_tokens(machine_id,node_id,node_token,enroll_token,node_boot_epoch) " ++
                 "VALUES(?1,?2,?3,?4,1);")
                #[mid, nodeId, nodeTok, enrollTok]

  let mbPath := System.FilePath.mk s!"{dataRoot}/mission_budgets.json"
  if (← mbPath.pathExists) then
    if let some raw ← (try some <$> IO.FS.readFile mbPath catch _ => pure none) then
      if let .ok (.obj kvs) := OrbBin.Json.parse raw then
        let entries := match (JVal.obj kvs).field? "budgets" with
          | some (.obj inner) => inner
          | _ => kvs
        for (mid, bv) in entries do
          if !mid.isEmpty then
            let dm? :=
              (bv.fieldUInt64? "budget_deci_milli_usd").orElse
                (fun _ => parseDeciMilliUsd? (bv.fieldOrNull "budget_usd") 0 1000000000)
            let rp := ((bv.fieldStr? "reset_period").getD "total").trimAscii.toString
            let vmLim := match bv.field? "vm_limits" with | some v@(.obj _) => renderCompact v | _ => ""
            let bwLim := match bv.field? "bandwidth_limits" with | some v@(.obj _) => renderCompact v | _ => ""
            discard <| saveMissionBudgetConfig mg {
              missionId := mid
              budgetDeciMilliUsd? := dm?
              resetPeriod := rp
              vmLimitsJson := vmLim
              bandwidthLimitsJson := bwLim
              updatedAt := nowSec
            }

  -- 6. Hydrate `project-context-state/<slug>/state.json` & `project-files/<slug>/` into `context_entries` / `context_heads`
  let ctxRoot := System.FilePath.mk s!"{dataRoot}/project-context-state"
  if (← ctxRoot.pathExists) then
    let slugDirs ← (try ctxRoot.readDir catch _ => pure #[])
    for sd in slugDirs do
      let slug := sd.fileName
      if validRawProjectSlug slug then
        let stJsonPath := sd.path / "state.json"
        if (← stJsonPath.pathExists) then
          if let some raw ← (try some <$> IO.FS.readFile stJsonPath catch _ => pure none) then
            if let .ok jv := OrbBin.Json.parse raw then
              let rev := (jv.fieldNat? "revision").getD 1
              if let some (.obj entKvs) := jv.field? "entries" then
                for (ePath, ev) in entKvs do
                  if (validContextPath ePath).isOk then
                    let kind := (ev.fieldStr? "kind").getD "file"
                    let isDirFlag := if kind == "dir" || ((ev.fieldBool? "directory").getD false) then "1" else "0"
                    let hash := ((ev.fieldStr? "content_hash").orElse (fun _ => ev.fieldStr? "hash")).getD ""
                    let sz := (ev.fieldNat? "size").getD 0
                    let er := (ev.fieldNat? "revision").getD rev
                    discard <| execParamQuery st.projectsDb
                      ("INSERT OR IGNORE INTO context_entries(project_slug,path,content_hash,directory,revision,size,deleted,source) " ++
                       "VALUES(?1,?2,?3,CAST(?4 AS INTEGER),CAST(?5 AS INTEGER),CAST(?6 AS INTEGER),0,'legacy');")
                      #[slug, ePath, hash, isDirFlag, s!"{er}", s!"{sz}"]
              discard <| execParamQuery st.projectsDb
                ("INSERT OR IGNORE INTO context_heads(project_slug,revision) VALUES(?1,CAST(?2 AS INTEGER));")
                #[slug, s!"{rev}"]

  let pfRoot := System.FilePath.mk s!"{dataRoot}/project-files"
  if (← pfRoot.pathExists) then
    let slugDirs ← (try pfRoot.readDir catch _ => pure #[])
    for sd in slugDirs do
      let slug := sd.fileName
      if validRawProjectSlug slug then
        hydrateProjectFilesTree st pfRoot slug nowIso

end OrbCore.LegacyHydrate
