/-
  One-time legacy state migration (`SEC-09`, `SEC-10`):
  - the historical Rust bunker JSON is imported once into `core_boot_state`
    under a monotonic maximum, fail-closed on corrupt state, and survives a
    restart without stale JSON undoing a later unbunker;
  - the historical nested `orb_telemetry` settings/token are imported once into
    the private `telemetry_config.json`, decrypting the old envelope and never
    enabling an unusable sink.
-/
import OrbCore.Store
import OrbCore.LegacyHydrate
import OrbCore.TelemetryAndVoice

namespace OrbCore.LegacyMigrationTests

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbNetLeaf.Crypto
open OrbCore.Store
open OrbCore.LegacyHydrate
open OrbCore.TelemetryAndVoice

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"legacy migration: {label}")

private def freshRoot (tag : String) : IO String := do
  let root := s!"/tmp/orb-legacy-migration-{tag}-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  return root

private def writeBunker (root : String) (raw : String) : IO Unit :=
  IO.FS.writeFile (legacyBunkerStatePath root) raw

private def migrateBunker! (root : String) (store : CoreStore) : IO Unit := do
  match ← migrateLegacyBunkerState root store with
  | .error e => throw (IO.userError s!"legacy migration: bunker migration failed: {e}")
  | .ok () => pure ()

private def migrateTelemetry! (root jwtSecret : String) (store : CoreStore) : IO Unit := do
  match ← migrateLegacyTelemetryState root root jwtSecret store with
  | .error e => throw (IO.userError s!"legacy migration: telemetry migration failed: {e}")
  | .ok () => pure ()

/-- Cold cutover for every valid historical bunker state, and restart persistence. -/
def testBunkerStatesAndRestart : IO Unit := do
  for (state, tag) in #[(0, "normal"), (1, "soft"), (2, "hard")] do
    let root ← freshRoot s!"bunker-{tag}"
    writeBunker root s!"\{\"bunker_state\":{state},\"requests\":[],\"audit\":[]}"
    let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
    try
      check (!(← legacyMigrationApplied? store "bunker_state")) s!"{tag}: marker starts absent"
      migrateBunker! root store
      check ((← readPersistedBunkerState store) == state.toUInt8) s!"{tag}: cold cutover imports state"
      check (← legacyMigrationApplied? store "bunker_state") s!"{tag}: marker is durable"
      closeCoreStore store
    catch e =>
      closeCoreStore store
      throw e
    let .ok reopened ← openCoreStore root | throw (IO.userError "legacy migration: store reopen failed")
    try
      check ((← readPersistedBunkerState reopened) == state.toUInt8) s!"{tag}: state survives restart"
      -- A stale legacy file must never override the already-migrated authority.
      writeBunker root "{\"bunker_state\":2}"
      migrateBunker! root reopened
      check ((← readPersistedBunkerState reopened) == state.toUInt8) s!"{tag}: stale JSON cannot re-import"
    finally
      closeCoreStore reopened

/-- Monotonic maximum on first import, and a later explicit unbunker wins forever. -/
def testBunkerMonotonicAndUnbunker : IO Unit := do
  let root ← freshRoot "bunker-monotonic"
  writeBunker root "{\"bunker_state\":2}"
  let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
  try
    match ← writePersistedBunkerState store 1 with
    | .error e => throw (IO.userError s!"legacy migration: seed state failed: {e}")
    | .ok () => pure ()
    migrateBunker! root store
    check ((← readPersistedBunkerState store) == 2) "first import takes the monotonic maximum"
    match ← writePersistedBunkerState store 0 with
    | .error e => throw (IO.userError s!"legacy migration: explicit unbunker failed: {e}")
    | .ok () => pure ()
  finally
    closeCoreStore store
  let .ok reopened ← openCoreStore root | throw (IO.userError "legacy migration: store reopen failed")
  try
    writeBunker root "{\"bunker_state\":2}"
    migrateBunker! root reopened
    check ((← readPersistedBunkerState reopened) == 0)
      "an explicitly signed unbunker survives restart and stale legacy JSON"
  finally
    closeCoreStore reopened

/-- Corrupt or ambiguous security state is refused, not silently normalised. -/
def testBunkerCorruptFailsClosed : IO Unit := do
  for (raw, tag) in #[
      ("not json", "invalid-json"),
      ("[]", "not-object"),
      ("{\"bunker_state\":3}", "out-of-range"),
      ("{\"bunker_state\":\"2\"}", "wrong-type")] do
    let root ← freshRoot s!"bunker-{tag}"
    writeBunker root raw
    let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
    try
      match ← migrateLegacyBunkerState root store with
      | .ok () => throw (IO.userError s!"legacy migration: corrupt state {tag} was accepted")
      | .error _ => pure ()
      check ((← readPersistedBunkerState store) == 0) s!"{tag}: live bunker stays unchanged"
      check (!(← legacyMigrationApplied? store "bunker_state")) s!"{tag}: failed input is not marked"
    finally
      closeCoreStore store

private def withLegacyKey (action : ByteArray → IO Unit) : IO Unit := do
  let priorKey ← IO.getEnv "PRIVATE_KEY"
  let priorFile ← IO.getEnv "PRIVATE_KEY_FILE"
  unsetenvVar "PRIVATE_KEY"
  unsetenvVar "PRIVATE_KEY_FILE"
  try
    let .ok key ← randBytes 32 | throw (IO.userError "legacy migration: csprng failed")
    action key
  finally
    match priorKey with
    | some v => setenvVar "PRIVATE_KEY" v
    | none => unsetenvVar "PRIVATE_KEY"
    match priorFile with
    | some v => setenvVar "PRIVATE_KEY_FILE" v
    | none => unsetenvVar "PRIVATE_KEY_FILE"

private def writeLegacyTelemetry (root : String) (key : ByteArray) (enabled prompts : Bool)
    (hubUrl ns token : String) : IO Unit := do
  let .ok encrypted ← encryptEnvValue key token
    | throw (IO.userError "legacy migration: old-envelope encryption failed")
  let tel := JVal.obj #[
    ("enabled", .bool enabled),
    ("prompts_enabled", .bool prompts),
    ("hub_url", .str hubUrl),
    ("namespace", .str ns),
    ("encrypted_token", .str encrypted)
  ]
  IO.FS.writeFile (OrbCore.SettingsFile.path root) (renderPretty (.obj #[("orb_telemetry", tel)]) ++ "\n")

/-- The legacy token migrates through the old key/envelope into the new private file. -/
def testTelemetryMigratesOnce : IO Unit := do
  withLegacyKey fun key => do
    let root ← freshRoot "telemetry"
    IO.FS.writeFile (System.FilePath.mk s!"{root}/private_key") (bytesToHexLower key)
    writeLegacyTelemetry root key true true "https://telemetry.example.test" "acme" "tl_live_legacy_token_123"
    let jwtSecret := "legacy-migration-jwt-secret-0123456789abcdef"
    let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
    try
      migrateTelemetry! root jwtSecret store
      check (← legacyMigrationApplied? store "telemetry") "telemetry migration marks once"
      let s ← loadTelemetrySettings root
      check (s.enabled && s.promptsEnabled && s.hubUrl == "https://telemetry.example.test" &&
        s.ns == some "acme") "legacy consent and destination are preserved"
      let some enc := s.encryptedToken
        | throw (IO.userError "legacy migration: migrated telemetry token is missing")
      check (enc.startsWith "v1:") "token is re-encrypted under the telemetry envelope"
      check ((← decryptTelemetryToken? jwtSecret root enc) == some "tl_live_legacy_token_123")
        "migrated token decrypts under the new key"
      -- The private file is authoritative: a later explicit disable + token clear
      -- is not undone by the old settings object on restart.
      match ← saveTelemetrySettings root { s with enabled := false, promptsEnabled := false, encryptedToken := none } with
      | .error e => throw (IO.userError s!"legacy migration: disable failed: {e}")
      | .ok () => pure ()
    finally
      closeCoreStore store
    let .ok reopened ← openCoreStore root | throw (IO.userError "legacy migration: store reopen failed")
    try
      migrateTelemetry! root jwtSecret reopened
      let s ← loadTelemetrySettings root
      check (!s.enabled && s.encryptedToken.isNone && !s.promptsEnabled)
        "stale legacy telemetry cannot undo an explicit disable"
    finally
      closeCoreStore reopened

/-- An existing private configuration wins even before the marker exists. -/
def testTelemetryPrivateConfigAuthoritative : IO Unit := do
  withLegacyKey fun key => do
    let root ← freshRoot "telemetry-authoritative"
    IO.FS.writeFile (System.FilePath.mk s!"{root}/private_key") (bytesToHexLower key)
    writeLegacyTelemetry root key true true "https://legacy.example.test" "legacy" "tl_live_legacy_token_999"
    let jwtSecret := "legacy-migration-jwt-secret-0123456789abcdef"
    let current : PersistedTelemetrySettings := {
      enabled := false, promptsEnabled := false, hubUrl := "https://current.example.test",
      ns := some "current", encryptedToken := none
    }
    match ← saveTelemetrySettings root current with
    | .error e => throw (IO.userError s!"legacy migration: current config write failed: {e}")
    | .ok () => pure ()
    let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
    try
      migrateTelemetry! root jwtSecret store
      let s ← loadTelemetrySettings root
      check (!s.enabled && s.hubUrl == "https://current.example.test" && s.ns == some "current" &&
        s.encryptedToken.isNone) "current private telemetry configuration is authoritative"
      check (← legacyMigrationApplied? store "telemetry") "authoritative config still marks the migration"
    finally
      closeCoreStore store

/-- Unusable legacy telemetry imports disabled, never enabled with a bad sink. -/
def testTelemetryCorruptFailsClosed : IO Unit := do
  withLegacyKey fun key => do
    let root ← freshRoot "telemetry-corrupt"
    IO.FS.writeFile (System.FilePath.mk s!"{root}/private_key") (bytesToHexLower key)
    let tel := JVal.obj #[
      ("enabled", .bool true), ("prompts_enabled", .bool true),
      ("hub_url", .str "https://telemetry.example.test"), ("namespace", .str "acme"),
      ("encrypted_token", .str "<encrypted v=\"1\">AAAA")
    ]
    IO.FS.writeFile (OrbCore.SettingsFile.path root) (renderPretty (.obj #[("orb_telemetry", tel)]) ++ "\n")
    let jwtSecret := "legacy-migration-jwt-secret-0123456789abcdef"
    let .ok store ← openCoreStore root | throw (IO.userError "legacy migration: store open failed")
    try
      migrateTelemetry! root jwtSecret store
      let s ← loadTelemetrySettings root
      check (!s.enabled && !s.promptsEnabled && s.encryptedToken.isNone)
        "undecryptable legacy token imports telemetry disabled"
      check (← legacyMigrationApplied? store "telemetry") "failed-closed import still marks once"
    finally
      closeCoreStore store

/-- Generic settings responses never project legacy telemetry ciphertext. -/
def testTelemetryRedactedFromSettings : IO Unit := do
  let settings := .obj #[("library_remote", .str "git@example.test:repo.git"),
    ("orb_telemetry", .obj #[("enabled", .bool true), ("encrypted_token", .str "<encrypted v=\"1\">ciphertext")])]
  let redacted := redactLegacyTelemetry settings
  check ((redacted.field? "orb_telemetry").isNone) "legacy telemetry object is not projected"
  check ((redacted.fieldStr? "library_remote") == some "git@example.test:repo.git")
    "other settings survive telemetry redaction"

def run : IO Unit := do
  testBunkerStatesAndRestart
  testBunkerMonotonicAndUnbunker
  testBunkerCorruptFailsClosed
  testTelemetryMigratesOnce
  testTelemetryPrivateConfigAuthoritative
  testTelemetryCorruptFailsClosed
  testTelemetryRedactedFromSettings

end OrbCore.LegacyMigrationTests
