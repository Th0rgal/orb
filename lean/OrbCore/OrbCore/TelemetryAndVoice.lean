/-
  OrbCore.TelemetryAndVoice: Multi-User Opt-In Usage Telemetry (`/api/usage-telemetry/*`) &
  Authenticated Speaker-Attributed Voice Transcription Relay (`/api/voice/transcribe`)
  (`0 import Lean`, `0 sorryAx`).

  Security & Isolation Invariants:
  1. Strict Allowlist Sanitization: Client events (`orb.approval.v1`, `orb.page.v1`, `orb.action.v1`)
     are reduced strictly to the schema fields in `shared/orb-spec/fixtures/usage-telemetry.json`.
  2. Authoritative Server-Side Actor Stamping: Any client-supplied `user_id` or `username` is stripped;
     Core stamps `user_id` and `username` exclusively from the authenticated session (`CallerPrincipal`)
     so one user (`benjamin`) can never spoof another (`thomas`).
  3. Admin-Only Configuration & Prompt Isolation: `PUT /api/usage-telemetry/config` requires `admin`;
     token is stored AES-256-GCM encrypted in a private `0600` file (`telemetry_config.json`), never
     logged and never returned by `GET /api/usage-telemetry`. Scrubbed `orb.prompt.v1` blobs are emitted
     only for `admin` turns when `prompts_enabled` is true, never for `member` accounts.
  4. Authenticated Voice Relay (`/api/voice/transcribe`): Validates mono 16 kHz 16-bit PCM WAV (`<= 4 MiB`,
     `0.1s..121s`), enforces a 2-slot concurrency cap, and stamps `X-Spark-Audio-Source: orb-voice`,
     `X-Spark-Speaker-Id: <username>`, `X-Orb-Username: <username>`, and `X-Orb-User-Id: <user_id>`
     so downstream `spark-memory` cleanly separates multi-user speakers (`thomas` vs `benjamin`).
-/
import Std.Sync.Mutex
import LeanSys
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.HttpClient
import OrbNetLeaf.Crypto
import OrbCore.Store

namespace OrbCore.TelemetryAndVoice

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.HttpClient
open OrbNetLeaf.Crypto
open OrbNetLeaf.TlsHttp
open OrbCore.Store

/-! ### 1. Shared Allowlist & Identifier Validation (`usage-telemetry.json`) -/

def defaultHubUrl : String := "https://telemetry.thomas.md"
def defaultVoiceTranscriptionUrl : String := "http://10.88.0.2:8000/v1/audio/transcriptions"
def telemetryBatchSize : Nat := 200
def telemetryQueueCap : Nat := 5000
def quickCloseMs : UInt64 := 2000
def maxVoiceAudioBytes : Nat := 4 * 1024 * 1024
def maxConcurrentVoiceSlots : Nat := 2

def isTelemetryIdentChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') ||
  c == '_' || c == '.' || c == ':' || c == '/' || c == '+' || c == '@' || c == '-'

/-- Matches `^[A-Za-z0-9_.:/+@-]{1,120}$` from `shared/orb-spec/fixtures/usage-telemetry.json`. -/
def isTelemetryIdent (s : String) : Bool :=
  let n := s.length
  1 ≤ n && n ≤ 120 && s.all isTelemetryIdentChar

/-- Matches `^[a-z0-9_-]{1,40}$` and rejects `"community"`. -/
def validTelemetryNamespace (ns : String) : Bool :=
  let n := ns.length
  ns != "community" && 1 ≤ n && n ≤ 40 &&
  ns.all (fun c => ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_' || c == '-')

/-- Hub URL must be `https://...` (or `http://` strictly on loopback `127.0.0.1` / `localhost` / `[::1]`)
    without embedded URL credentials (`user:pass@`). -/
def hubUrlAllowed (rawUrl : String) : Bool :=
  let u := rawUrl.trimAscii.toString
  if (u.splitOn "@").length > 1 then false
  else
    match OrbBin.HttpClient.parseUrl u with
    | .error _ => false
    | .ok p =>
      if p.isHttps then !p.host.isEmpty
      else p.host == "127.0.0.1" || p.host == "localhost" || p.host == "::1"

inductive FieldSpec where
  | uint
  | bool
  | ident
  | client
  | schema
  | enumOf (allowed : Array String)
  deriving Repr, BEq

def allowedClients : Array String := #["desktop", "ios", "android", "core"]
def allowedClientSchemas : Array String := #["orb.approval.v1", "orb.page.v1", "orb.action.v1"]

def commonFieldSpecs : Array (String × FieldSpec) := #[
  ("schema", .schema),
  ("event_id", .ident),
  ("ts", .ident),
  ("client", .client),
  ("app_version", .ident),
  ("user_id", .ident),
  ("username", .ident)
]

def schemaFieldSpecs? (schema : String) : Option (Array (String × FieldSpec)) :=
  if schema == "orb.approval.v1" then
    some #[
      ("kind", .enumOf #["tool", "command_class", "grant", "payment"]),
      ("decision", .enumOf #["approved", "denied", "expired", "dismissed"]),
      ("method", .enumOf #["face_id", "touch_id", "passcode", "desktop_click", "none"]),
      ("wait_ms", .uint),
      ("tool_name", .ident),
      ("command_class", .ident)
    ]
  else if schema == "orb.page.v1" then
    some #[
      ("screen", .ident),
      ("surface", .enumOf #["screen", "sheet", "pane"]),
      ("dwell_ms", .uint),
      ("entry_point", .ident)
    ]
  else if schema == "orb.action.v1" then
    some #[
      ("action", .enumOf #[
        "sidebar_move", "btw", "fork", "queue", "file_viewer_open",
        "inbox_open", "inbox_archive", "inbox_snooze", "inbox_done",
        "message_edit", "message_resend"
      ]),
      ("count", .uint),
      ("surface", .ident)
    ]
  else if schema == "orb.turn.v1" then
    some #[
      ("model", .ident),
      ("harness", .ident),
      ("session_id", .ident),
      ("input_tokens", .uint),
      ("output_tokens", .uint),
      ("cache_read_tokens", .uint),
      ("cost_cents", .uint),
      ("latency_ms", .uint),
      ("interrupted", .bool),
      ("resent", .bool)
    ]
  else if schema == "orb.prompt.v1" then
    some #[
      ("session_id", .ident),
      ("prompt_digest", .ident),
      ("chars", .uint)
    ]
  else
    none

private def keepFieldValue (spec : FieldSpec) (v : JVal) : Option JVal :=
  match spec with
  | .uint =>
    match v.asUInt64? with
    | some n => some (.uint64 n)
    | none => none
  | .bool =>
    match v.asBool? with
    | some b => some (.bool b)
    | none => none
  | .ident =>
    match v.asStr? with
    | some s => if isTelemetryIdent s then some (.str s) else none
    | none => none
  | .client =>
    match v.asStr? with
    | some s => if allowedClients.contains s then some (.str s) else none
    | none => none
  | .schema =>
    match v.asStr? with
    | some s => some (.str s)
    | none => none
  | .enumOf allowed =>
    match v.asStr? with
    | some s => if allowed.contains s then some (.str s) else none
    | none => none

/-- Sanitize an event against `shared/orb-spec/fixtures/usage-telemetry.json`, strip any client-supplied
    `user_id`/`username` when `fromClient == true`, and stamp authoritative `actorUserId?`/`actorUsername?`
    when valid identifiers. -/
def sanitizeTelemetryEvent
    (ev : JVal)
    (fromClient : Bool)
    (actorUserId? : Option String := none)
    (actorUsername? : Option String := none) : Except String JVal := do
  let some schema := ev.fieldStr? "schema"
    | throw "missing schema"
  let some sFields := schemaFieldSpecs? schema
    | throw "unknown schema"
  if fromClient && !allowedClientSchemas.contains schema then
    throw "core-only schema"
  let some clientStr := ev.fieldStr? "client"
    | throw "unknown client"
  if !allowedClients.contains clientStr then
    throw "unknown client"
  let mut out : Array (String × JVal) := #[]
  for (k, spec) in commonFieldSpecs ++ sFields do
    if fromClient && (k == "user_id" || k == "username") then
      pure ()
    else if let some rawV := ev.field? k then
      if let some cleanV := keepFieldValue spec rawV then
        out := out.push (k, cleanV)
  if schema == "orb.page.v1" then
    if let some dwell := (JVal.obj out).fieldUInt64? "dwell_ms" then
      out := out.push ("quick_close", .bool (dwell < quickCloseMs))
  let mut res := JVal.obj out
  if let some uid := actorUserId? then
    let t := uid.trimAscii.toString
    if isTelemetryIdent t then
      res := res.setField "user_id" (.str t)
  if let some uname := actorUsername? then
    let t := uname.trimAscii.toString
    if isTelemetryIdent t then
      res := res.setField "username" (.str t)
  return res

/-! ### 2. Pure Secret Scrubber (`scrub_secrets` fixture parity) -/

private def isAlphaNum (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')

private def isWordChar (c : Char) : Bool :=
  isAlphaNum c || c == '_'

private def isTokenBodyChar (c : Char) : Bool :=
  isAlphaNum c || c == '_' || c == '-'

private def isBearerTokenChar (c : Char) : Bool :=
  isAlphaNum c || c == '.' || c == '_' || c == '~' || c == '+' || c == '/' || c == '-' || c == '='

private def charsMatchAt (cs : Array Char) (pos : Nat) (pat : List Char) : Bool :=
  match pat with
  | [] => true
  | p :: ps =>
    if pos < cs.size && cs[pos]! == p then charsMatchAt cs (pos + 1) ps else false

private def charsMatchAtCI (cs : Array Char) (pos : Nat) (patLower : List Char) : Bool :=
  match patLower with
  | [] => true
  | p :: ps =>
    if pos < cs.size && cs[pos]!.toLower == p then charsMatchAtCI cs (pos + 1) ps else false

private def takeWhileCount (cs : Array Char) (pos : Nat) (pred : Char → Bool) : Nat := Id.run do
  let mut k := 0
  while pos + k < cs.size && pred cs[pos + k]! do
    k := k + 1
  return k

/-- Scrub PEM private keys (`-----BEGIN ... PRIVATE KEY----- ... -----END ... PRIVATE KEY-----`). -/
private def scrubPemPrivateKeys (s : String) : String := Id.run do
  let cs := s.toList.toArray
  let beginPat := "-----BEGIN ".toList
  let privPat := "PRIVATE KEY-----".toList
  let endPrefix := "-----END ".toList
  let mut out : Array Char := Array.mkEmpty cs.size
  let mut i : Nat := 0
  while i < cs.size do
    if charsMatchAt cs i beginPat then
      let mut j := i + beginPat.length
      while j < cs.size && (('A' ≤ cs[j]! && cs[j]! ≤ 'Z') || cs[j]! == ' ') do
        j := j + 1
      if charsMatchAt cs j privPat then
        let mut k := j + privPat.length
        let mut closedEnd : Option Nat := none
        while k < cs.size && closedEnd.isNone do
          if charsMatchAt cs k endPrefix then
            let mut m := k + endPrefix.length
            while m < cs.size && (('A' ≤ cs[m]! && cs[m]! ≤ 'Z') || cs[m]! == ' ') do
              m := m + 1
            if charsMatchAt cs m privPat then
              closedEnd := some (m + privPat.length)
          k := k + 1
        if let some afterEnd := closedEnd then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := afterEnd
        else
          out := out.push cs[i]!
          i := i + 1
      else
        out := out.push cs[i]!
        i := i + 1
    else
      out := out.push cs[i]!
      i := i + 1
  return String.ofList out.toList

/-- Scrub URL userinfo credentials (`://user:pass@` -> `://[REDACTED]@`). -/
private def scrubUrlCredentials (s : String) : String := Id.run do
  let cs := s.toList.toArray
  let sep := "://".toList
  let mut out : Array Char := Array.mkEmpty cs.size
  let mut i : Nat := 0
  while i < cs.size do
    if charsMatchAt cs i sep then
      let uStart := i + 3
      let uLen := takeWhileCount cs uStart (fun c => c != '/' && !c.isWhitespace && c != ':' && c != '@')
      if uLen > 0 && uStart + uLen < cs.size && cs[uStart + uLen]! == ':' then
        let pStart := uStart + uLen + 1
        let pLen := takeWhileCount cs pStart (fun c => c != '/' && !c.isWhitespace && c != '@')
        if pLen > 0 && pStart + pLen < cs.size && cs[pStart + pLen]! == '@' then
          for rc in "://[REDACTED]@".toList do out := out.push rc
          i := pStart + pLen + 1
        else
          out := out.push cs[i]!; i := i + 1
      else
        out := out.push cs[i]!; i := i + 1
    else
      out := out.push cs[i]!; i := i + 1
  return String.ofList out.toList

private def hasSecretKeyKeyword (ident : String) : Bool :=
  let low := ident.toLower
  (low.splitOn "secret").length > 1 ||
  (low.splitOn "token").length > 1 ||
  (low.splitOn "password").length > 1 ||
  (low.splitOn "passwd").length > 1 ||
  (low.splitOn "apikey").length > 1 ||
  (low.splitOn "api_key").length > 1 ||
  (low.splitOn "privatekey").length > 1 ||
  (low.splitOn "private_key").length > 1

/-- Scrub fixed-prefix tokens (OpenAI/Anthropic `sk-`/`pk-`/`rk-`, `tl_live_`, GitHub `gh*_` / `github_pat_`,
    AWS `AKIA`, Slack `xox*-`, Google `AIza`, JWT `eyJ...`, `Bearer <tok>`, and `KEY = value` pairs). -/
def scrubSecrets (raw : String) : String := Id.run do
  let s1 := scrubUrlCredentials (scrubPemPrivateKeys raw)
  let cs := s1.toList.toArray
  let mut out : Array Char := Array.mkEmpty cs.size
  let mut i : Nat := 0
  while i < cs.size do
    let atWordBoundary := i == 0 || !isWordChar cs[i - 1]!
    if atWordBoundary then
      -- 1. JWT: eyJ<8+>.<8+>.<8+>
      if charsMatchAt cs i ['e', 'y', 'J'] then
        let l1 := takeWhileCount cs (i + 3) isTokenBodyChar
        let p1 := i + 3 + l1
        if 3 + l1 ≥ 8 && p1 < cs.size && cs[p1]! == '.' then
          let l2 := takeWhileCount cs (p1 + 1) isTokenBodyChar
          let p2 := p1 + 1 + l2
          if l2 ≥ 8 && p2 < cs.size && cs[p2]! == '.' then
            let l3 := takeWhileCount cs (p2 + 1) isTokenBodyChar
            if l3 ≥ 8 then
              for rc in "[REDACTED]".toList do out := out.push rc
              i := p2 + 1 + l3
              continue
      -- 2. sk- / pk- / rk-
      if charsMatchAt cs i ['s', 'k', '-'] || charsMatchAt cs i ['p', 'k', '-'] || charsMatchAt cs i ['r', 'k', '-'] then
        let l := takeWhileCount cs (i + 3) isTokenBodyChar
        if l ≥ 16 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 3 + l
          continue
      -- 3. tl_live_ / tl_test_
      if charsMatchAt cs i "tl_live_".toList || charsMatchAt cs i "tl_test_".toList then
        let l := takeWhileCount cs (i + 8) isAlphaNum
        if l ≥ 8 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 8 + l
          continue
      -- 4. ghp_ / gho_ / ghu_ / ghs_ / ghr_
      if i + 4 < cs.size && cs[i]! == 'g' && cs[i + 1]! == 'h' &&
         (cs[i + 2]! == 'p' || cs[i + 2]! == 'o' || cs[i + 2]! == 'u' || cs[i + 2]! == 's' || cs[i + 2]! == 'r') &&
         cs[i + 3]! == '_' then
        let l := takeWhileCount cs (i + 4) isAlphaNum
        if l ≥ 20 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 4 + l
          continue
      -- 5. github_pat_
      if charsMatchAt cs i "github_pat_".toList then
        let l := takeWhileCount cs (i + 11) (fun c => isAlphaNum c || c == '_')
        if l ≥ 20 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 11 + l
          continue
      -- 6. AKIA[0-9A-Z]{16}\b
      if charsMatchAt cs i "AKIA".toList then
        let l := takeWhileCount cs (i + 4) (fun c => ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9'))
        if l == 16 && (i + 20 ≥ cs.size || !isWordChar cs[i + 20]!) then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 20
          continue
      -- 7. xox[abpr]-
      if i + 5 < cs.size && cs[i]! == 'x' && cs[i + 1]! == 'o' && cs[i + 2]! == 'x' &&
         (cs[i + 3]! == 'a' || cs[i + 3]! == 'b' || cs[i + 3]! == 'p' || cs[i + 3]! == 'r') &&
         cs[i + 4]! == '-' then
        let l := takeWhileCount cs (i + 5) (fun c => isAlphaNum c || c == '-')
        if l ≥ 10 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 5 + l
          continue
      -- 8. AIza[0-9A-Za-z_-]{35}
      if charsMatchAt cs i "AIza".toList then
        let l := takeWhileCount cs (i + 4) isTokenBodyChar
        if l ≥ 35 then
          for rc in "[REDACTED]".toList do out := out.push rc
          i := i + 4 + 35
          continue
      -- 9. Bearer <tok>
      if charsMatchAtCI cs i "bearer".toList && i + 6 < cs.size && cs[i + 6]!.isWhitespace then
        let wsLen := takeWhileCount cs (i + 6) Char.isWhitespace
        let tokStart := i + 6 + wsLen
        let tokLen := takeWhileCount cs tokStart isBearerTokenChar
        if tokLen ≥ 16 then
          for k in [i : tokStart] do out := out.push cs[k]!
          for rc in "[REDACTED]".toList do out := out.push rc
          i := tokStart + tokLen
          continue
      -- 10. KEY['"]?\s*[:=]\s*['"]?<val{4,}>
      let kLen := takeWhileCount cs i isTokenBodyChar
      if kLen > 0 then
        let keyIdent := String.ofList (cs.extract i (i + kLen)).toList
        if hasSecretKeyKeyword keyIdent then
          let mut p := i + kLen
          if p < cs.size && (cs[p]! == '\'' || cs[p]! == '"') then p := p + 1
          p := p + takeWhileCount cs p Char.isWhitespace
          if p < cs.size && (cs[p]! == ':' || cs[p]! == '=') then
            p := p + 1
            p := p + takeWhileCount cs p Char.isWhitespace
            if p < cs.size && (cs[p]! == '\'' || cs[p]! == '"') then p := p + 1
            let vLen := takeWhileCount cs p (fun c => !c.isWhitespace && c != '\'' && c != '"')
            if vLen ≥ 4 then
              for k in [i : p] do out := out.push cs[k]!
              for rc in "[REDACTED]".toList do out := out.push rc
              i := p + vLen
              continue
    out := out.push cs[i]!
    i := i + 1
  return String.ofList out.toList

/-! ### 3. Encrypted Telemetry Config & Bounded Queue (`TelemetrySink`) -/

structure PersistedTelemetrySettings where
  enabled        : Bool   := false
  promptsEnabled : Bool   := false
  hubUrl         : String := defaultHubUrl
  ns             : Option String := none
  encryptedToken : Option String := none
  deriving Repr, BEq

structure HubTarget where
  url       : String
  ns        : String
  token     : String
  prompts   : Bool
  deriving BEq

structure TelemetryQueueState where
  target?    : Option HubTarget := none
  events     : Array JVal := #[]
  blobs      : Array (String × String) := #[]
  failures   : UInt32 := 0
  retryAtSec : UInt64 := 0
  lastError? : Option String := none

structure TelemetrySink where
  mu : Std.Mutex TelemetryQueueState

def newTelemetrySink : IO TelemetrySink := do
  let m ← Std.Mutex.new {}
  return { mu := m }

private def deriveTelemetryAeadKey (jwtSecret rootDir : String) : ByteArray :=
  let material := if jwtSecret.isEmpty then s!"orb-dev-telemetry:{rootDir}" else jwtSecret
  hmacSha256Bytes material.toUTF8 "orb-usage-telemetry-token-v1".toUTF8

def encryptTelemetryToken (jwtSecret rootDir plainToken : String) : IO (Except String String) := do
  let key32 := deriveTelemetryAeadKey jwtSecret rootDir
  let .ok nonce12 ← randBytes 12
    | return .error "csprng_failed"
  let .ok ctTag ← aeadSeal .aes256Gcm key32 nonce12 "orb-telemetry-v1".toUTF8 plainToken.toUTF8
    | return .error "aead_seal_failed"
  return .ok ("v1:" ++ base64Encode (nonce12 ++ ctTag) true false)

def decryptTelemetryToken? (jwtSecret rootDir encToken : String) : IO (Option String) := do
  let t := encToken.trimAscii.toString
  if !t.startsWith "v1:" then return none
  let some raw := base64Decode? (t.drop 3).toString
    | return none
  if raw.size < 28 then return none
  let nonce12 := raw.extract 0 12
  let ctTag := raw.extract 12 raw.size
  let key32 := deriveTelemetryAeadKey jwtSecret rootDir
  match ← aeadOpen .aes256Gcm key32 nonce12 "orb-telemetry-v1".toUTF8 ctTag with
  | .error _ => return none
  | .ok pt => return (String.fromUTF8? pt).map (·.trimAscii.toString) |>.filter (!·.isEmpty)

private def telemetryConfigPath (rootDir : String) : System.FilePath :=
  System.FilePath.mk rootDir / "telemetry_config.json"

def loadTelemetrySettings (rootDir : String) : IO PersistedTelemetrySettings := do
  let p := telemetryConfigPath rootDir
  if !(← p.pathExists) then return {}
  let raw ← try IO.FS.readFile p catch _ => pure ""
  match OrbBin.Json.parse raw with
  | .error _ => return {}
  | .ok jv =>
    let en := (jv.fieldBool? "enabled").getD false
    let pr := en && ((jv.fieldBool? "prompts_enabled").getD false)
    let url := ((jv.fieldStr? "hub_url").map (·.trimAscii.toString)).filter (!·.isEmpty) |>.getD defaultHubUrl
    let ns? := ((jv.fieldStr? "namespace").map (·.trimAscii.toString)).filter (!·.isEmpty)
    let tok? := ((jv.fieldStr? "encrypted_token").map (·.trimAscii.toString)).filter (!·.isEmpty)
    return { enabled := en, promptsEnabled := pr, hubUrl := url, ns := ns?, encryptedToken := tok? }

def saveTelemetrySettings (rootDir : String) (s : PersistedTelemetrySettings) : IO (Except String Unit) := do
  let obj := JVal.obj #[
    ("enabled", .bool s.enabled),
    ("prompts_enabled", .bool (s.enabled && s.promptsEnabled)),
    ("hub_url", .str s.hubUrl),
    ("namespace", match s.ns with | some n => .str n | none => .null),
    ("encrypted_token", match s.encryptedToken with | some t => .str t | none => .null)
  ]
  writeAtomicPrivate0600 (telemetryConfigPath rootDir) (OrbBin.Json.renderPretty obj).toUTF8

def resolveHubTarget (jwtSecret rootDir : String) (s : PersistedTelemetrySettings) : IO (Option HubTarget) := do
  if !s.enabled then return none
  let some ns := s.ns.filter validTelemetryNamespace
    | return none
  if !hubUrlAllowed s.hubUrl then return none
  let some enc := s.encryptedToken
    | return none
  let some tok ← decryptTelemetryToken? jwtSecret rootDir enc
    | return none
  return some { url := stripTrailingSlash s.hubUrl, ns := ns, token := tok, prompts := s.promptsEnabled }

def syncSinkTarget (sink : TelemetrySink) (target? : Option HubTarget) : IO Unit :=
  sink.mu.atomically do
    if target?.isNone then
      set ({} : TelemetryQueueState)
    else
      modify fun q => { q with target? := target? }

def renderTelemetryStatusJson (s : PersistedTelemetrySettings) (sink : TelemetrySink) : IO String := do
  let (active, queued, lastErr?) ← sink.mu.atomically do
    let q ← get
    return (q.target?.isSome, q.events.size, q.lastError?)
  let nsJson := match s.ns with | some n => .str n | none => .null
  let errJson := match lastErr? with | some e => .str e | none => .null
  let out := JVal.obj #[
    ("enabled", .bool s.enabled),
    ("prompts_enabled", .bool s.promptsEnabled),
    ("active", .bool active),
    ("hub_url", .str s.hubUrl),
    ("namespace", nsJson),
    ("token_configured", .bool s.encryptedToken.isSome),
    ("queued", .nat queued),
    ("last_error", errJson)
  ]
  return OrbBin.Json.renderCompact out

private def formatIsoSimple (epochSec : UInt64) : String :=
  s!"epoch-{epochSec}"

private def enqueueSanitizedEvent
    (sink : TelemetrySink)
    (ev : JVal)
    (blob? : Option (String × String))
    (nowEpochSec : UInt64) : IO Bool := do
  let newId ← newUuidV4
  sink.mu.atomically do
    let q ← get
    if q.target?.isNone then
      return false
    let mut finalEv := ev
    if (finalEv.fieldStr? "event_id").isNone then
      finalEv := finalEv.setField "event_id" (.str newId)
    if (finalEv.fieldStr? "ts").isNone then
      finalEv := finalEv.setField "ts" (.str (formatIsoSimple nowEpochSec))
    let pushed := q.events.push finalEv
    let bounded :=
      if pushed.size > telemetryQueueCap then
        pushed.extract (pushed.size - telemetryQueueCap) pushed.size
      else
        pushed
    let nextBlobs :=
      match blob? with
      | none => q.blobs
      | some (dg, txt) =>
        let filtered := q.blobs.filter (fun (k, _) => k != dg)
        let b2 := filtered.push (dg, txt)
        if b2.size > telemetryQueueCap then b2.extract (b2.size - telemetryQueueCap) b2.size else b2
    set { q with events := bounded, blobs := nextBlobs }
    return true

/-- Accept a batch of client events (`POST /api/usage-telemetry/events`), stamping `actorUserId?`
    and `actorUsername?` from the authenticated Core session. Returns `(enabled, acceptedCount)`. -/
def acceptClientTelemetryBatch
    (sink : TelemetrySink)
    (rawEvents : Array JVal)
    (actorUserId? actorUsername? : Option String)
    (nowEpochSec : UInt64) : IO (Bool × Nat) := do
  let isEnabled ← sink.mu.atomically do return (← get).target?.isSome
  if !isEnabled then
    return (false, 0)
  let capped := if rawEvents.size > telemetryBatchSize then rawEvents.extract 0 telemetryBatchSize else rawEvents
  let mut accepted : Nat := 0
  for item in capped do
    match sanitizeTelemetryEvent item true actorUserId? actorUsername? with
    | .error _ => pure ()
    | .ok cleanEv =>
      if (← enqueueSanitizedEvent sink cleanEv none nowEpochSec) then
        accepted := accepted + 1
  return (true, accepted)

/-- Record an admin-opted-in scrubbed `orb.prompt.v1` event on `POST /api/control/message`.
    Strictly skipped for non-admin (`member`) callers so another user's prompt text is never
    exported into the instance owner's telemetry blobs. -/
def observeControlUserPrompt
    (sink : TelemetrySink)
    (isCallerAdmin : Bool)
    (actorUserId? actorUsername? : Option String)
    (missionId content : String)
    (nowEpochSec : UInt64) : IO Unit := do
  if !isCallerAdmin || content.trimAscii.toString.isEmpty then
    return
  let promptsOn ← sink.mu.atomically do
    return match (← get).target? with | some t => t.prompts | none => false
  if !promptsOn then
    return
  let scrubbed := scrubSecrets content
  let digest := bytesToHexLower (sha256Bytes scrubbed.toUTF8)
  let rawEv := JVal.obj #[
    ("schema", .str "orb.prompt.v1"),
    ("client", .str "core"),
    ("session_id", .str missionId),
    ("prompt_digest", .str digest),
    ("chars", .nat scrubbed.length)
  ]
  if let .ok cleanEv := sanitizeTelemetryEvent rawEv false actorUserId? actorUsername? then
    discard <| enqueueSanitizedEvent sink cleanEv (some (digest, scrubbed)) nowEpochSec

/-- Flush up to one batch (`200` events) from `sink` to `<hub_url>/v2/ns/<namespace>/ingest`. -/
def flushTelemetryOnce (sink : TelemetrySink) (nowEpochSec : UInt64) : IO (Except String Nat) := do
  let snap? ← sink.mu.atomically do
    let q ← get
    match q.target? with
    | none => return none
    | some tgt =>
      if q.events.isEmpty || nowEpochSec < q.retryAtSec then
        return none
      let batch := if q.events.size > telemetryBatchSize then q.events.extract 0 telemetryBatchSize else q.events
      let mut batchBlobs : Array (String × JVal) := #[]
      for ev in batch do
        if let some dg := ev.fieldStr? "prompt_digest" then
          if let some (_, txt) := q.blobs.find? (fun (k, _) => k == dg) then
            if !batchBlobs.any (fun (k, _) => k == dg) then
              batchBlobs := batchBlobs.push (dg, .str txt)
      return some (tgt, batch, batchBlobs)
  let some (tgt, batch, batchBlobs) := snap?
    | return .ok 0
  let ingestUrl := s!"{stripTrailingSlash tgt.url}/v2/ns/{tgt.ns}/ingest"
  let payload := OrbBin.Json.renderCompact (JVal.obj #[
    ("events", .arr batch),
    ("blobs", .obj batchBlobs)
  ])
  let hdrs := #[
    ("Authorization", s!"Bearer {tgt.token}"),
    ("Content-Type", "application/json")
  ]
  let resp ← OrbBin.HttpClient.sendRequest "POST" ingestUrl hdrs payload.toUTF8 15000 1048576
  sink.mu.atomically do
    let q ← get
    let dropBatch (st : TelemetryQueueState) : TelemetryQueueState :=
      let remEvents := st.events.extract (Nat.min batch.size st.events.size) st.events.size
      let sentDigests := batchBlobs.map Prod.fst
      let remBlobs := st.blobs.filter (fun (k, _) => !sentDigests.contains k)
      { st with events := remEvents, blobs := remBlobs }
    match resp with
    | .ok r =>
      if 200 ≤ r.status && r.status < 300 then
        let q' := dropBatch q
        set { q' with failures := 0, retryAtSec := 0, lastError? := none }
        return .ok batch.size
      else
        let retry := r.status ≥ 500 || r.status == 429 || r.status == 408
        let msg := s!"hub returned {r.status}"
        if retry then
          let f := q.failures + 1
          let shift := Nat.min f.toNat 5
          let backoff := Nat.min (30 * (1 <<< shift)) 600
          set { q with failures := f, retryAtSec := nowEpochSec + backoff.toUInt64, lastError? := some msg }
        else
          let q' := dropBatch q
          set { q' with lastError? := some msg }
        return .error msg
    | .error _ =>
      let f := q.failures + 1
      let shift := Nat.min f.toNat 5
      let backoff := Nat.min (30 * (1 <<< shift)) 600
      let msg := "hub unreachable"
      set { q with failures := f, retryAtSec := nowEpochSec + backoff.toUInt64, lastError? := some msg }
      return .error msg

/-! ### 4. Authenticated Speaker-Attributed Voice Relay (`POST /api/voice/transcribe`) -/

def supportedVoiceLanguages : Array String := #[
  "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"
]

private def readWavU16LE (b : ByteArray) (p : Nat) : UInt16 :=
  (b.get! p).toUInt16 ||| ((b.get! (p + 1)).toUInt16 <<< 8)

private def readWavU32LE (b : ByteArray) (p : Nat) : Nat :=
  (b.get! p).toNat |||
  ((b.get! (p + 1)).toNat <<< 8) |||
  ((b.get! (p + 2)).toNat <<< 16) |||
  ((b.get! (p + 3)).toNat <<< 24)

private def ascii4Eq (b : ByteArray) (off : Nat) (s4 : String) : Bool :=
  let p := s4.toUTF8
  off + 4 ≤ b.size && p.size == 4 &&
  b.get! off == p.get! 0 &&
  b.get! (off + 1) == p.get! 1 &&
  b.get! (off + 2) == p.get! 2 &&
  b.get! (off + 3) == p.get! 3

/-- Validate mono 16 kHz, 16-bit PCM WAV (`3200 .. 121 * 32000` sample bytes, `<= 4 MiB`),
    matching `voice.rs` chunk framing byte-for-byte. -/
def validateVoiceWav (wav : ByteArray) : Except String Unit := Id.run do
  let invalid := "Expected a mono 16 kHz, 16-bit PCM WAV (up to 120 seconds)."
  if wav.size < 44 || wav.size > maxVoiceAudioBytes ||
     !ascii4Eq wav 0 "RIFF" || !ascii4Eq wav 8 "WAVE" then
    return .error invalid
  if readWavU32LE wav 4 + 8 != wav.size then
    return .error invalid
  let mut offset : Nat := 12
  let mut sawFmt := false
  let mut sawData := false
  while offset + 8 ≤ wav.size do
    let sz := readWavU32LE wav (offset + 4)
    let start := offset + 8
    let chunkEnd := start + sz
    if chunkEnd > wav.size then
      return .error invalid
    if ascii4Eq wav offset "fmt " then
      if sawFmt || sz < 16 ||
         readWavU16LE wav start != 1 ||
         readWavU16LE wav (start + 2) != 1 ||
         readWavU32LE wav (start + 4) != 16000 ||
         readWavU32LE wav (start + 8) != 32000 ||
         readWavU16LE wav (start + 12) != 2 ||
         readWavU16LE wav (start + 14) != 16 then
        return .error invalid
      sawFmt := true
    else if ascii4Eq wav offset "data" then
      if sawData || sz < 3200 || sz > 121 * 32000 || sz % 2 != 0 then
        return .error invalid
      sawData := true
    offset := chunkEnd + (sz % 2)
  if !sawFmt || !sawData || offset != wav.size then
    return .error invalid
  return .ok ()

/-- Normalize an authenticated Orb username/userId into a safe header/form speaker identifier,
    failing closed to `"unknown"` when absent or malformed so non-Thomas speakers never collide with `"thomas"`. -/
def canonicalOrbSpeakerId (username userId : String) (isLegacyUnscoped : Bool) : String :=
  if isLegacyUnscoped then "unknown"
  else
    let clean (s : String) : String :=
      let t := s.trimAscii.toString.toLower
      if t.isEmpty || t.length > 64 then ""
      else if t.all (fun c => ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_' || c == '-' || c == '.') then t
      else ""
    let u := clean username
    if !u.isEmpty && u != "default" then u
    else
      let uid := clean userId
      if !uid.isEmpty && uid != "default" then uid else "unknown"

private def buildVoiceMultipartBody
    (boundary language speakerId userId : String)
    (wav : ByteArray) : ByteArray := Id.run do
  let addTextField (acc : ByteArray) (name val : String) : ByteArray :=
    acc ++
    s!"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{val}\r\n".toUTF8
  let mut out := ByteArray.emptyWithCapacity (wav.size + 512)
  out := addTextField out "model" "cohere-transcribe"
  out := addTextField out "language" language
  out := addTextField out "response_format" "json"
  out := addTextField out "speaker_id" speakerId
  if !userId.isEmpty then
    out := addTextField out "user_id" userId
  out := out ++
    s!"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".toUTF8 ++
    wav ++
    s!"\r\n--{boundary}--\r\n".toUTF8
  return out

structure VoiceRelaySlots where
  active : Std.Mutex Nat

def newVoiceRelaySlots : IO VoiceRelaySlots := do
  let m ← Std.Mutex.new 0
  return { active := m }

/-- Validate and forward a mobile dictation WAV to `SANDBOXED_VOICE_TRANSCRIPTION_URL`
    with bounded concurrency (`2` slots) and speaker attribution headers + form fields. -/
def transcribeVoiceRelay
    (slots : VoiceRelaySlots)
    (language : String)
    (wav : ByteArray)
    (callerUserId callerUsername : String)
    (isLegacyUnscoped : Bool)
    (endpointOverride? : Option String := none) : IO (Nat × String) := do
  let lang := language.trimAscii.toString
  if !supportedVoiceLanguages.contains lang then
    return (400, "{\"error\":\"Unsupported dictation language.\"}")
  if let .error msg := validateVoiceWav wav then
    return (400, s!"\{\"error\":{escapeJsonString msg}}")
  let acquired ← slots.active.atomically do
    let cur ← get
    if cur ≥ maxConcurrentVoiceSlots then
      return false
    set (cur + 1)
    return true
  if !acquired then
    return (503, "{\"error\":\"Dictation is busy. Please retry shortly.\"}")
  try
    let endpoint ← match endpointOverride? with
      | some ov => pure ov
      | none =>
        match ← getEnvNonEmpty "SANDBOXED_VOICE_TRANSCRIPTION_URL" with
        | some u => pure u
        | none => pure defaultVoiceTranscriptionUrl
    let token? ← getEnvNonEmpty "SANDBOXED_VOICE_TRANSCRIPTION_TOKEN"
    let speakerId := canonicalOrbSpeakerId callerUsername callerUserId isLegacyUnscoped
    let safeUid := if isTelemetryIdent callerUserId.trimAscii.toString then callerUserId.trimAscii.toString else ""
    let safeUname := if isTelemetryIdent callerUsername.trimAscii.toString then callerUsername.trimAscii.toString else speakerId
    let boundaryHex ← match ← randBytes 12 with
      | .ok b => pure (bytesToHexLower b)
      | .error _ => pure "0123456789abcdef01234567"
    let boundary := s!"----OrbVoiceBoundary{boundaryHex}"
    let body := buildVoiceMultipartBody boundary lang speakerId safeUid wav
    let mut hdrs : Array (String × String) := #[
      ("Content-Type", s!"multipart/form-data; boundary={boundary}"),
      ("X-Spark-Audio-Source", "orb-voice"),
      ("X-Spark-Speaker-Id", speakerId),
      ("X-Orb-Username", safeUname)
    ]
    if !safeUid.isEmpty then
      hdrs := hdrs.push ("X-Orb-User-Id", safeUid)
    if let some tok := token? then
      hdrs := hdrs.push ("Authorization", s!"Bearer {tok.trimAscii.toString}")
    let unavail := (503, "{\"error\":\"Transcription is unavailable. Your recording can be retried.\"}")
    match ← OrbBin.HttpClient.sendRequest "POST" endpoint hdrs body 90000 65536 with
    | .error _ => return unavail
    | .ok resp =>
      if resp.status < 200 || resp.status ≥ 300 || resp.body.size > 64 * 1024 then
        return unavail
      match OrbBin.Json.parseBytes resp.body with
      | .error _ => return unavail
      | .ok jv =>
        let some txt := jv.fieldStr? "text"
          | return unavail
        return (200, OrbBin.Json.renderCompact (JVal.obj #[("text", .str txt.trimAscii.toString)]))
  finally
    slots.active.atomically do
      modify fun n => if n > 0 then n - 1 else 0

end OrbCore.TelemetryAndVoice
