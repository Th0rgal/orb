import OrbCore.SettingsCli

namespace OrbCore.SettingsTransferTests

open OrbBin.Json OrbBin.PosixExt OrbCore.Store OrbCore.Managed

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"settings transfer: {label}")

private def require {α : Type} (action : IO (Except String α)) : IO α := do
  match ← action with
  | .ok value => return value
  | .error error => throw (IO.userError s!"settings fixture failed: {error}")

private def sql (db : SqliteDb) (stmt : String) (params : Array String := #[]) : IO Unit := do
  discard <| require (execParamQuery db stmt params)

private def fixture (root uid marker : String) (source : Bool) : IO (CoreStore × ManagedComputeStore) := do
  let st ← require (openCoreStore root)
  let mc ← require (openManagedComputeStore s!"{root}/managed_compute.db")
  sql st.missionsDb
    "INSERT INTO users(id,username,password_hash,role,session_epoch,daily_spend_cap_cents) VALUES(?1,'Admin',?2,'admin',7,?3);"
    #[uid, marker ++ "-password", if source then "500" else "100"]
  sql st.missionsDb "INSERT INTO missions(id,title,status,owner_user_id) VALUES(?1,?1,'awaiting_user',?2);" #[marker ++ "-mission", uid]
  sql st.missionsDb "INSERT INTO user_daily_spend(user_id,utc_day,inference_cents) VALUES(?1,'2026-11-13',33);" #[uid]
  sql st.missionsDb
    "INSERT INTO ai_providers(id,provider_type,name,enabled,api_key,base_url) VALUES('openai','openai','OpenAI',?1,?2,?3);"
    #[if source then "1" else "0", marker ++ "-provider-key", "https://" ++ marker ++ ".invalid"]
  sql st.missionsDb
    "INSERT INTO model_routing_chains(id,name,models_json,is_default,strip_thinking) VALUES('custom','Custom',?1,0,0);"
    #[renderCompact (.arr #[.obj #[("provider_id", .str "openai"), ("model_id", .str "gpt-6"),
      ("api_key", .str (marker ++ "-inline-key"))]])]
  sql st.missionsDb "INSERT INTO user_provider_prefs(user_id,provider_id,enabled) VALUES(?1,'openai',?2);" #[uid, if source then "1" else "0"]
  require <| saveManagedFleetConfig mc source source (if source then 300 else 100) 77 (if source then 2 else 1)
  sql mc.db "INSERT INTO managed_provider_settings(provider,enabled) VALUES('leanci',?1);" #[if source then "0" else "1"]
  sql mc.db "INSERT INTO core_monitor_settings(singleton_id,data) VALUES(1,?1);"
    #[renderCompact (.obj #[("stall_minutes", .num (if source then "15" else "30"))])]
  sql mc.db "INSERT INTO user_managed_provider_prefs(user_id,provider,enabled) VALUES(?1,'boat',?2);" #[uid, if source then "0" else "1"]
  require <| sealProviderSecret root "boat" (marker ++ "-sealed-key")
  require <| SettingsFile.write root (.obj #[("bws_access_token", .str (marker ++ "-vault-token")),
    ("dashboard_password_hash", .str (marker ++ "-dashboard-hash")),
    ("max_parallel_missions", .num (if source then "3" else "1"))])
  let library := root ++ "/library"
  IO.FS.createDirAll library
  let init ← IO.Process.output { cmd := "git", args := #["-C", library, "init", "-q"] }
  let commit ← IO.Process.output { cmd := "git", args := #["-C", library, "-c", "user.name=Fixture",
    "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", marker] }
  check (init.exitCode == 0 && commit.exitCode == 0) "seed local Library revision"
  return (st, mc)

private def invariant (st : CoreStore) (mc : ManagedComputeStore) : IO String := do
  let mut all := ""
  for statement in #[
      "SELECT id,username,password_hash,role,session_epoch,disabled FROM users ORDER BY id;",
      "SELECT id,title,owner_user_id FROM missions ORDER BY id;",
      "SELECT * FROM user_daily_spend ORDER BY user_id;",
      "SELECT id,api_key,base_url FROM ai_providers ORDER BY id;",
      "SELECT * FROM core_boot_state;"] do
    let rows ← require (execParamQuery st.missionsDb statement #[])
    all := all ++ reprStr rows
  for statement in #["SELECT spent_today_cents FROM managed_fleet_state;", "SELECT * FROM managed_machines;"] do
    let rows ← require (execParamQuery mc.db statement #[])
    all := all ++ reprStr rows
  let file ← require (SettingsFile.read st.rootDir)
  all := all ++ renderCompact (file.value.fieldOrNull "bws_access_token") ++
    renderCompact (file.value.fieldOrNull "dashboard_password_hash")
  let sealed ← IO.FS.readBinFile (managedSecretPath st.rootDir "boat")
  return all ++ reprStr sealed.toList

def run : IO Unit := do
  let nonce ← IO.monoNanosNow
  let parent := s!"/tmp/orb-settings-transfer-{nonce}"
  let prodRoot := parent ++ "/prod"
  let devRoot := parent ++ "/dev"
  let (prod, prodMc) ← fixture prodRoot "prod-local-id" "source" true
  let (dev, devMc) ← fixture devRoot "dev-local-id" "target" false
  try
    let doc ← require (SettingsTransfer.exportDocument prodRoot)
    let rendered := SettingsDocument.render doc
    check (((doc.fieldOrNull "global").fieldStr? "library_revision").any SettingsDocument.validLibraryRevision)
      "export captures the current Library commit when no explicit pin exists"
    check ((rendered.splitOn "source-password").length == 1 && (rendered.splitOn "source-provider-key").length == 1 &&
      (rendered.splitOn "source-inline-key").length == 1 && (rendered.splitOn "source-vault-token").length == 1 &&
      (rendered.splitOn "source-mission").length == 1 && (rendered.splitOn "prod-local-id").length == 1)
      "export projects configuration without credentials, account IDs or missions"
    let protectedBefore ← invariant dev devMc
    let sourceBefore ← invariant prod prodMc
    let initial ← require (SettingsTransfer.exportDocument devRoot)
    let removed := doc.setField "routing_chains" (.arr
      (((doc.fieldArr? "routing_chains").getD #[]).filter (fun chain => chain.fieldStr? "id" != some "custom")))
    check (!(← SettingsTransfer.preview devRoot removed).isOk)
      "deleting a chain cannot discard local inline credentials"
    let replaced := doc.setField "routing_chains" (.arr
      (((doc.fieldArr? "routing_chains").getD #[]).map fun chain =>
        if chain.fieldStr? "id" == some "custom" then chain.setField "entries" (.arr #[.obj
          #[("provider_id", .str "openai"), ("model_id", .str "other-model")]]) else chain))
    check (!(← SettingsTransfer.preview devRoot replaced).isOk)
      "replacing an entry cannot discard local inline credentials"
    let (before, delta) ← require (SettingsTransfer.preview devRoot doc)
    check ((delta.splitOn "+ fleet:").length == 2) "preview prints before/after settings diff"
    check (protectedBefore == (← invariant dev devMc) &&
      SettingsDocument.render initial == SettingsDocument.render (← require (SettingsTransfer.exportDocument devRoot)))
      "preview does not mutate configuration or protected data"
    let settingsPath := SettingsFile.path devRoot
    let fileBefore ← IO.FS.readFile settingsPath
    let blocked ← SettingsTransfer.importDocument devRoot doc before (fun _ _ => pure (.error "fixture_write_failed"))
    check (!blocked.isOk && fileBefore == (← IO.FS.readFile settingsPath) &&
      SettingsDocument.render initial == SettingsDocument.render (← require (SettingsTransfer.exportDocument devRoot)))
      "settings write failure rolls back both SQL databases"
    sql dev.missionsDb "CREATE TABLE settings_commit_parent(id INTEGER PRIMARY KEY);"
    sql dev.missionsDb "CREATE TABLE settings_commit_child(id INTEGER REFERENCES settings_commit_parent(id) DEFERRABLE INITIALLY DEFERRED);"
    sql dev.missionsDb "CREATE TRIGGER settings_commit_fail AFTER UPDATE OF enabled ON ai_providers BEGIN INSERT INTO settings_commit_child VALUES(123); END;"
    let commitFailed ← SettingsTransfer.importDocument devRoot doc before
    check (!commitFailed.isOk && fileBefore == (← IO.FS.readFile settingsPath) &&
      SettingsDocument.render initial == SettingsDocument.render (← require (SettingsTransfer.exportDocument devRoot)))
      "commit failure rolls back SQL and restores the exact original settings file"
    sql dev.missionsDb "DROP TRIGGER settings_commit_fail;"
    let edited := initial.setField "global" ((initial.fieldOrNull "global").setField "max_parallel_missions" (.num "2"))
    require <| SettingsTransfer.importDocument devRoot edited before
    check (!(← SettingsTransfer.importDocument devRoot doc before).isOk) "stale confirmation cannot overwrite a concurrent settings edit"
    let (fresh, _) ← require (SettingsTransfer.preview devRoot doc)
    require <| SettingsTransfer.importDocument devRoot doc fresh
    check (rendered == SettingsDocument.render (← require (SettingsTransfer.exportDocument devRoot)))
      "prod export, dev import and dev export are byte-identical across different local user IDs"
    check (protectedBefore == (← invariant dev devMc) && sourceBefore == (← invariant prod prodMc))
      "accounts, missions, counters, secrets, provider URLs and source instance remain untouched"
    let inline ← require (execParamQuery dev.missionsDb "SELECT models_json FROM model_routing_chains WHERE id='custom';" #[])
    check (((reprStr inline).splitOn "target-inline-key").length == 2 && ((reprStr inline).splitOn "source-inline-key").length == 1)
      "matching routing credentials stay local to the target"
    let unknown := doc.setField "user_preferences" (.arr #[.obj #[("username", .str "missing"),
      ("inference", .arr #[]), ("managed", .arr #[]), ("daily_spend_cap_cents", .null)]])
    check (!(← SettingsTransfer.preview devRoot unknown).isOk) "missing users are rejected before import; no users are created"
    let badProvider := doc.setField "inference_providers" (.arr #[])
    check (!(← SettingsTransfer.preview devRoot badProvider).isOk) "provider catalogs must already match"
    require <| writeAtomicPrivate0600 (parent ++ "/document.json") rendered.toUTF8
    let markers := #["SANDBOXED_MISSION_ID", "SANDBOXED_SH_MISSION_ID", "SANDBOXED_JOB_ID"]
    let oldMarkers ← markers.mapM (fun name => do return ← IO.getEnv name)
    try
      for marker in markers do unsetenvVar marker
      check ((← SettingsCli.run ["refresh-dev", "--prod-root", prodRoot, "--dev-root", devRoot] "unused") == 0)
        "refresh dev previews the same transfer path"
      check ((← SettingsCli.run ["promote-dev", "--prod-root", prodRoot, "--dev-root", devRoot, "--yes"] "unused") == 0)
        "promotion requires explicit confirmation and uses existing target users"
      setenvVar "SANDBOXED_MISSION_ID" "fixture-mission"
      check ((← SettingsCli.run ["export", "--data-root", devRoot, "--output", parent ++ "/denied.json"] "unused") == 1)
        "mission environments cannot invoke the local operator CLI"
      check (!(← (System.FilePath.mk (parent ++ "/denied.json")).pathExists)) "denied export writes no document"
    finally
      for i in [:markers.size] do
        match oldMarkers[i]! with
        | some value => setenvVar markers[i]! value
        | none => unsetenvVar markers[i]!
    check (!(SettingsCli.parse ["promote-dev", "--data-root", devRoot, "--yes"] devRoot).isOk)
      "direction commands reject ignored target overrides"
    let lock ← flockExclusiveNb s!"{devRoot}/.settings.lock"
    check (lock < 0xFFFFFFFE) "fixture lock acquired"
    try check (!(← SettingsTransfer.exportDocument devRoot).isOk) "busy settings fail instead of returning an empty export"
    finally closeFdRaw lock.toInt32
    IO.FS.writeFile settingsPath "not-json"
    check (!(← SettingsTransfer.exportDocument devRoot).isOk) "corrupt settings never become an empty export"
    check (!(← SettingsFile.write devRoot (.obj #[])).isOk) "regular writers cannot erase a corrupt settings file"
  finally
    closeCoreStore prod
    closeCoreStore dev
    closeManagedComputeStore prodMc
    closeManagedComputeStore devMc
    IO.FS.removeDirAll parent

end OrbCore.SettingsTransferTests
