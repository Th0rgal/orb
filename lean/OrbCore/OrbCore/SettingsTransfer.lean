/-
Operator configuration transfer over existing stores. No CoreStore startup,
schema migration, user creation, credential lookup or mission-state access.
-/
import OrbCore.Store
import OrbCore.Managed
import OrbCore.SettingsDocument
import OrbCore.SettingsFile
import OrbCore.LocalOperator
import OrbCore.ProxyModelRouting
import OrbCore.Skills

namespace OrbCore.SettingsTransfer

open OrbBin.Json OrbBin.PosixExt OrbCore.Store OrbCore.Managed

private abbrev Action := ExceptT String IO

private def query (db : SqliteDb) (sql : String) (params : Array String := #[]) : Action (Array (Array String)) :=
  ExceptT.mk do
    match ← execParamQueryUnlocked db sql params with
    | .ok rows => return .ok (rows.extract 1 rows.size)
    | .error _ => return .error "settings_store_unavailable"

private def withStore {α : Type} (root : String) (action : SqliteDb → IO (Except String α)) : IO (Except String α) := do
  if !(← OrbCore.LocalOperator.ownsRoot root) then return .error "settings_root_unavailable"
  let (missions, _) ← resolveCoreStoreDbPaths root
  let managed := s!"{root}/managed_compute.db"
  for file in #[missions, managed] do
    let st ← statPath file
    if !st.isReg || st.isSymlink || !st.ownedByEuid then return .error "settings_store_missing"
  let handle ← sqliteOpenRaw missions
  if handle == 0 then return .error "settings_store_unavailable"
  try
    let db : SqliteDb := { handle, path := missions, mu := ← Std.Mutex.new () }
    let .ok _ ← execParamQuery db "ATTACH DATABASE ?1 AS cfg_managed;" #[managed]
      | return .error "settings_store_unavailable"
    action db
  finally sqliteCloseRaw handle

private def project (value : JVal) (fields : Array (String × SettingsDocument.Scalar)) : JVal :=
  .obj (fields.filterMap fun (key, _) => (value.field? key).map (key, ·))

private def toggles (rows : Array (Array String)) : JVal :=
  .arr (rows.map fun row => .obj #[("id", .str (row.getD 0 "")), ("enabled", .bool (row.getD 1 "" == "1"))])

private def readDocument (db : SqliteDb) (settings : JVal) (root : String) : Action JVal := do
  let mut global := project settings SettingsDocument.globalFields
  if (global.field? "library_revision").isNone then
    let library ← ExceptT.lift (Skills.resolveLibraryRoot root root)
    let revision ← ExceptT.lift do
      try
        let output ← IO.Process.output { cmd := "git", args := #["-C", library, "rev-parse", "--verify", "HEAD"] }
        let revision := output.stdout.trimAscii.toString
        return if output.exitCode == 0 && SettingsDocument.validLibraryRevision revision then some revision else none
      catch _ => return none
    global := global.setField "library_revision" (revision.map JVal.str |>.getD .null)
  let chainRows ← query db ProxyModelRouting.chainRowsSql
  let chains := (ProxyModelRouting.chainResponses chainRows (fun _ => "") "").map fun chain =>
    (chain.removeField "created_at").removeField "updated_at"
  let providers ← query db "SELECT id,enabled FROM ai_providers ORDER BY id;"
  let fleetRows ← query db "SELECT enabled,boat_enabled,daily_cap_cents,max_concurrent FROM cfg_managed.managed_fleet_state WHERE singleton_id=1;"
  let some fleet := fleetRows[0]? | throw "settings_fleet_missing"
  let managedRows ← query db "SELECT provider,enabled FROM cfg_managed.managed_provider_settings ORDER BY provider;"
  let monitorRows ← query db "SELECT data FROM cfg_managed.core_monitor_settings WHERE singleton_id=1;"
  let .ok monitorObj@(.obj monitorPairs) := OrbBin.Json.parse ((monitorRows[0]?).map (·.getD 0 "{}") |>.getD "{}")
    | throw "settings_monitor_invalid"
  let mut monitor := SettingsDocument.monitorDefaults
  for (key, value) in monitorPairs do monitor := monitor.setField key value
  -- Preserve strict validation of stored thresholds rather than dropping unknown data.
  if monitorObj.asObj?.isNone then throw "settings_monitor_invalid"
  let managed := (knownProviders.qsort (· < ·)).map fun name =>
    let enabled := if name == "boat" then fleet.getD 1 "" == "1" else
      !(managedRows.any (fun row => row.getD 0 "" == name && row.getD 1 "" == "0"))
    .obj #[("id", .str name), ("enabled", .bool enabled)]
  let users ← query db "SELECT id,lower(username),daily_spend_cap_cents FROM users ORDER BY lower(username);"
  let mut preferences : Array JVal := #[]
  for user in users do
    let inference ← query db "SELECT provider_id,enabled FROM user_provider_prefs WHERE user_id=?1 ORDER BY provider_id;" #[user.getD 0 ""]
    let compute ← query db "SELECT provider,enabled FROM cfg_managed.user_managed_provider_prefs WHERE user_id=?1 ORDER BY provider;" #[user.getD 0 ""]
    let cap := user.getD 2 ""
    preferences := preferences.push (.obj #[("username", .str (user.getD 1 "")),
      ("inference", toggles inference), ("managed", toggles compute),
      ("daily_spend_cap_cents", if cap.isEmpty then .null else .num cap)])
  let doc := JVal.obj #[
    ("version", .num "1"), ("global", global),
    ("routing_chains", .arr chains), ("inference_providers", toggles providers),
    ("managed_providers", .arr managed), ("user_preferences", .arr preferences),
    ("fleet", .obj #[("enabled", .bool (fleet.getD 0 "" == "1")),
      ("boat_enabled", .bool (fleet.getD 1 "" == "1")),
      ("daily_cap_cents", .num (fleet.getD 2 "")), ("max_concurrent", .num (fleet.getD 3 ""))]),
    ("monitor", monitor)]
  liftExcept (SettingsDocument.validate doc)
  return doc

/-- Strict export: a failed query is an error, never an empty replacement document. -/
def exportDocument (root : String) : IO (Except String JVal) :=
  SettingsFile.withLock root do
    let .ok snapshot ← SettingsFile.read root | return .error "settings_file_unavailable"
    withStore root fun db => withImmediateTx db (readDocument db snapshot.value root).run

private def array (doc : JVal) (key : String) : Array JVal := (doc.fieldArr? key).getD #[]
private def text (row : JVal) (key : String) : String := (row.fieldStr? key).getD ""
private def flag (row : JVal) (key : String) : String := if row.fieldBool? key == some true then "1" else "0"
private def count (row : JVal) (key : String) : String := renderCompact (row.fieldOrNull key)

private def preflight (db : SqliteDb) (doc : JVal) : Action (Array (String × String)) := do
  let providers ← query db "SELECT id FROM ai_providers;"
  let known := providers.map (fun row => row.getD 0 "")
  let incoming := (array doc "inference_providers").map (text · "id")
  if incoming.size != known.size || incoming.any (!known.contains ·) then throw "settings_provider_catalog_differs"
  let incomingManaged := (array doc "managed_providers").map (text · "id")
  if incomingManaged.size != knownProviders.size || incomingManaged.any (!knownProviders.contains ·) then
    throw "settings_managed_provider_catalog_differs"
  let chains := array doc "routing_chains"
  -- Inline settings can contain a key that exists only on this instance. A
  -- configuration transfer must not discard it by deleting its chain/entry.
  let storedChains ← query db "SELECT id,models_json FROM model_routing_chains;"
  for row in storedChains do
    let stored := row.getD 1 "[]"
    let .ok (.arr oldEntries) := OrbBin.Json.parse stored | throw "settings_routing_invalid"
    let incoming := (chains.find? (fun chain => text chain "id" == row.getD 0 "")).map
      (fun chain => renderCompact (chain.fieldOrNull "entries")) |>.getD "[]"
    let .ok (.arr retained) := OrbBin.Json.parse (ProxyModelRouting.keepStoredEntrySettings incoming stored)
      | throw "settings_routing_invalid"
    for entry in oldEntries do
      let .obj fields := entry | throw "settings_routing_invalid"
      if fields.any (fun (key, _) => !#["provider_id", "provider", "model_id", "modelId"].contains key) then
        unless retained.any (fun kept => renderCompact (SettingsDocument.canonical kept) ==
            renderCompact (SettingsDocument.canonical entry)) do
          throw "settings_would_remove_local_routing_settings"
  for (id, _, _) in ProxyModelRouting.stockChains do
    unless chains.any (fun chain => text chain "id" == id) do throw "settings_builtin_chain_missing"
  unless (chains.filter (fun chain => chain.fieldBool? "is_default" == some true)).size == 1 do
    throw "settings_default_chain_required"
  let boat? := (array doc "managed_providers").find? (fun row => text row "id" == "boat")
  if boat?.bind (·.fieldBool? "enabled") != (doc.fieldOrNull "fleet").fieldBool? "boat_enabled" then
    throw "settings_boat_flag_conflicts_with_fleet"
  let mut users : Array (String × String) := #[]
  for prefs in array doc "user_preferences" do
    let username := text prefs "username"
    let found ← query db "SELECT id FROM users WHERE username=?1 COLLATE NOCASE;" #[username]
    let some user := found[0]? | throw "settings_target_user_missing"
    users := users.push (username, user.getD 0 "")
    for pref in array prefs "inference" do
      unless known.contains (text pref "id") do throw "settings_target_provider_missing"
    for pref in array prefs "managed" do
      unless knownProviders.contains (text pref "id") do throw "settings_target_provider_missing"
  return users

private def applySql (db : SqliteDb) (doc : JVal) (users : Array (String × String)) : Action Unit := do
  let oldChains ← query db "SELECT id,models_json FROM model_routing_chains;"
  let desired := array doc "routing_chains"
  for row in oldChains do
    if !(desired.any (fun item => text item "id" == row.getD 0 "")) then
      discard <| query db "DELETE FROM model_routing_chains WHERE id=?1;" #[row.getD 0 ""]
  for chain in desired do
    let id := text chain "id"
    let old := (oldChains.find? (fun row => row.getD 0 "" == id)).map (·.getD 1 "[]") |>.getD "[]"
    let entries := ProxyModelRouting.keepStoredEntrySettings (renderCompact (chain.fieldOrNull "entries")) old
    discard <| query db
      ("INSERT INTO model_routing_chains(id,name,models_json,is_default,strip_thinking) VALUES(?1,?2,?3,?4,?5) " ++
       "ON CONFLICT(id) DO UPDATE SET name=excluded.name,models_json=excluded.models_json,is_default=excluded.is_default,strip_thinking=excluded.strip_thinking;")
      #[id, text chain "name", entries, flag chain "is_default", flag chain "strip_thinking"]
  for provider in array doc "inference_providers" do
    discard <| query db "UPDATE ai_providers SET enabled=?2 WHERE id=?1;" #[text provider "id", flag provider "enabled"]
  for provider in array doc "managed_providers" do
    if text provider "id" != "boat" then
      discard <| query db
        ("INSERT INTO cfg_managed.managed_provider_settings(provider,enabled) VALUES(?1,?2) " ++
         "ON CONFLICT(provider) DO UPDATE SET enabled=excluded.enabled;") #[text provider "id", flag provider "enabled"]
  for prefs in array doc "user_preferences" do
    let some (_, uid) := users.find? (fun entry => entry.1 == text prefs "username")
      | throw "settings_target_user_missing"
    discard <| query db "UPDATE users SET daily_spend_cap_cents=NULLIF(?2,'null') WHERE id=?1;" #[uid, count prefs "daily_spend_cap_cents"]
    discard <| query db "DELETE FROM user_provider_prefs WHERE user_id=?1;" #[uid]
    for pref in array prefs "inference" do
      discard <| query db "INSERT INTO user_provider_prefs(user_id,provider_id,enabled) VALUES(?1,?2,?3);" #[uid, text pref "id", flag pref "enabled"]
    discard <| query db "DELETE FROM cfg_managed.user_managed_provider_prefs WHERE user_id=?1;" #[uid]
    for pref in array prefs "managed" do
      discard <| query db "INSERT INTO cfg_managed.user_managed_provider_prefs(user_id,provider,enabled) VALUES(?1,?2,?3);" #[uid, text pref "id", flag pref "enabled"]
  let fleet := doc.fieldOrNull "fleet"
  discard <| query db
    "UPDATE cfg_managed.managed_fleet_state SET enabled=?1,boat_enabled=?2,daily_cap_cents=?3,max_concurrent=?4 WHERE singleton_id=1;"
    #[flag fleet "enabled", flag fleet "boat_enabled", count fleet "daily_cap_cents", count fleet "max_concurrent"]
  discard <| query db
    ("INSERT INTO cfg_managed.core_monitor_settings(singleton_id,data) VALUES(1,?1) " ++
     "ON CONFLICT(singleton_id) DO UPDATE SET data=excluded.data;") #[renderCompact (doc.fieldOrNull "monitor")]

private def mergeFile (current doc : JVal) : JVal := Id.run do
  let mut next := current
  for (key, _) in SettingsDocument.globalFields do
    next := next.removeField key
  for (key, value) in (doc.fieldOrNull "global").asObj?.getD #[] do
    next := next.setField key value
  return next

/-- Confirmation applies the snapshot whose diff the caller printed. Locks serialize
    both databases and settings-file writers; ordinary failures restore all three.
    A private, non-secret before-document remains available for operator recovery. -/
def importDocument (root : String) (doc before : JVal)
    (writeFile : String → JVal → IO (Except String Unit) := SettingsFile.writeUnlocked) : IO (Except String Unit) := do
  if let .error e := SettingsDocument.validate doc then return .error e
  if let .error e := SettingsDocument.validate before then return .error e
  SettingsFile.withLock root do
    let .ok snapshot ← SettingsFile.read root | return .error "settings_file_unavailable"
    let wrote ← IO.mkRef false
    let result ← try withStore root fun db => withImmediateTx db (do
      let live ← readDocument db snapshot.value root
      if SettingsDocument.render live != SettingsDocument.render before then throw "settings_changed"
      let users ← preflight db doc
      let backup := System.FilePath.mk root / "settings-before-import.json"
      let .ok () ← ExceptT.lift (writeAtomicPrivate0600 backup (SettingsDocument.render live).toUTF8)
        | throw "settings_backup_failed"
      applySql db doc users
      let .ok () ← ExceptT.lift (writeFile root (mergeFile snapshot.value doc))
        | throw "settings_file_write_failed"
      ExceptT.lift (wrote.set true)
      : Action Unit).run
      catch _ => pure (.error "settings_import_failed")
    if !result.isOk && (← wrote.get) then
      if let .error _ ← SettingsFile.restoreUnlocked root snapshot then return .error "settings_restore_failed_use_backup"
    return result

/-- Diff-only preview performs target compatibility validation without mutation. -/
def preview (root : String) (doc : JVal) : IO (Except String (JVal × String)) := do
  if let .error e := SettingsDocument.validate doc then return .error e
  SettingsFile.withLock root do
    let .ok snapshot ← SettingsFile.read root | return .error "settings_file_unavailable"
    withStore root fun db => withImmediateTx db (do
      let before ← readDocument db snapshot.value root
      discard <| preflight db doc
      let delta ← liftExcept (SettingsDocument.diff before doc)
      return (before, delta) : Action (JVal × String)).run

end OrbCore.SettingsTransfer
