import OrbCore.Control
import OrbCore.ManagedProvisioningTests
import OrbCore.ProviderUsageAndLogin
import OrbCore.MissionBoard

namespace OrbCore.TenantIsolationTests

open OrbCore.Control OrbCore.MemoryAndCloud OrbCore.Store OrbCore.Managed OrbCore.ProviderUsageAndLogin OrbCore.LegacyHydrate OrbBin.Json LeanSys.Http LeanSys.Posix

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"tenant isolation: {label}")

set_option maxHeartbeats 800000
set_option maxRecDepth 200000

/-- Owner decision 2026-11-14 (docs/MULTI_USER.md "Shared inference providers"): members add
    and edit shared accounts, never read credentials, delete only what they added, and every
    member write is audited by field name only. -/
def memberSharedProviderRules
    (send : String → String → String → JVal → CoreAppState → IO (Nat × JVal))
    (member admin : String) (app : CoreAppState) (store : CoreStore) (ownerName : String) : IO Unit := do
  let secret := "sk-member-probe-secret-marker"
  let has (doc : JVal) (m : String) := ((renderCompact doc).splitOn m).length > 1
  -- member_add_api_key_account_is_write_only_and_server_ids
  let (addSt, added) ← send "POST" "/api/ai/providers" member (.obj #[("id", .str "prov-anth-1"),
    ("provider_type", .str "openai"), ("name", .str "ben-probe"), ("api_key", .str secret)]) app
  let probeId := (added.fieldStr? "id").getD ""
  check (addSt == 201 && !probeId.isEmpty && probeId != "prov-anth-1" &&
    added.fieldStr? "created_by_user_id" == some "member" && !has added secret)
    s!"member_add_api_key_account_is_write_only_and_server_ids (got {addSt})"
  let some ownerRow ← getAIProvider? store "prov-anth-1" | check false "owner row survives member add"
  check (ownerRow.apiKey == "sk-ant-secret-key-marker-1" && ownerRow.createdByUserId.isEmpty)
    "member_add_cannot_overwrite_owner_account"
  -- member_sees_full_own_account_and_reduced_others
  let (_, mList) ← send "GET" "/api/ai/providers" member (.obj #[]) app
  let rows := mList.asArr?.getD #[]
  let own := (rows.find? (·.fieldStr? "id" == some probeId)).getD .null
  check (own.fieldStr? "name" == some "ben-probe" && own.fieldBool? "added_by_me" == some true &&
    own.fieldStr? "created_by_username" == some "member" && !has mList secret && !has mList ownerName &&
    !has mList "sk-ant-secret" && !has mList "admin-provider-name-marker-beta")
    "member_sees_full_own_account_and_reduced_others"
  let (_, mDetail) ← send "GET" s!"/api/ai/providers/{probeId}" member (.obj #[]) app
  check (mDetail.fieldStr? "name" == some "ben-probe" && !has mDetail secret) "member_get_own_account_detail_without_key"
  -- member_edit_own_account_settings_and_rotate_key
  let (editSt, edited) ← send "PUT" s!"/api/ai/providers/{probeId}" member (.obj #[("name", .str "ben-probe-2"),
    ("rpm_limit", .nat 30), ("enabled", .bool false), ("api_key", .str (secret ++ "-rotated"))]) app
  let some stored ← getAIProvider? store probeId | check false "probe row stored"
  check (editSt == 200 && edited.fieldStr? "name" == some "ben-probe-2" && !has edited secret &&
    stored.apiKey == secret ++ "-rotated" && stored.rpmLimit? == some 30 && !stored.enabled &&
    stored.createdByUserId == "member")
    s!"member_edit_own_account_settings_and_rotate_key (got {editSt})"
  -- member_edit_shared_owner_account_settings_reduced_response
  let (shSt, shDoc) ← send "PUT" "/api/ai/providers/prov-anth-1" member (.obj #[("name", .str "member-renamed"),
    ("rpm_limit", .nat 99)]) app
  let some ownerAfter ← getAIProvider? store "prov-anth-1" | check false "owner row after member edit"
  check (shSt == 200 && ownerAfter.name == "member-renamed" && ownerAfter.rpmLimit? == some 99 &&
    ownerAfter.apiKey == "sk-ant-secret-key-marker-1" && !has shDoc "sk-ant-secret" && (shDoc.field? "base_url").isNone)
    s!"member_edit_shared_owner_account_settings_reduced_response (got {shSt})"
  -- member_cannot_replace_owner_credentials_or_endpoint
  let (keySt, _) ← send "PUT" "/api/ai/providers/prov-anth-1" member (.obj #[("api_key", .str "sk-hijack")]) app
  let (urlSt, _) ← send "PUT" "/api/ai/providers/prov-anth-1" member (.obj #[("base_url", .str "https://evil.example")]) app
  let some ownerKept ← getAIProvider? store "prov-anth-1" | check false "owner row kept"
  check (keySt == 403 && urlSt == 403 && ownerKept.apiKey == "sk-ant-secret-key-marker-1")
    s!"member_cannot_replace_owner_credentials_or_endpoint (key {keySt}, url {urlSt})"
  let (restoreSt, _) ← send "PUT" "/api/ai/providers/prov-anth-1" admin (.obj #[("name", .str ownerName), ("rpm_limit", .nat 4321)]) app
  check (restoreSt == 200) "admin restores owner fixture"
  -- member_base_url_only_public_https_on_custom
  let (bu1, _) ← send "POST" "/api/ai/providers" member (.obj #[("provider_type", .str "anthropic"),
    ("name", .str "x"), ("base_url", .str "https://api.example.com")]) app
  let (bu2, _) ← send "POST" "/api/ai/providers" member (.obj #[("provider_type", .str "custom"),
    ("name", .str "x"), ("base_url", .str "http://127.0.0.1:3002")]) app
  let (bu3, _) ← send "POST" "/api/ai/providers" member (.obj #[("provider_type", .str "custom"),
    ("name", .str "x"), ("base_url", .str "https://10.0.0.5/v1")]) app
  let (bu4, c4) ← send "POST" "/api/ai/providers" member (.obj #[("provider_type", .str "custom"),
    ("name", .str "ben-custom"), ("base_url", .str "https://api.example.com/v1"), ("api_key", .str secret)]) app
  check (bu1 == 403 && bu2 == 403 && bu3 == 403 && bu4 == 201) s!"member_base_url_only_public_https_on_custom ({bu1},{bu2},{bu3},{bu4})"
  -- member_added_account_never_inherits_instance_env_key
  let priorEnv ← IO.getEnv "ANTHROPIC_API_KEY"
  OrbBin.PosixExt.setenvVar "ANTHROPIC_API_KEY" "sk-ant-instance-env-marker"
  let (_, noKey) ← send "POST" "/api/ai/providers" member (.obj #[("provider_type", .str "anthropic"), ("name", .str "ben-nokey")]) app
  let noKeyId := (noKey.fieldStr? "id").getD ""
  let (_, noKeyDoc) ← send "GET" s!"/api/ai/providers/{noKeyId}" member (.obj #[]) app
  match priorEnv with
  | some v => OrbBin.PosixExt.setenvVar "ANTHROPIC_API_KEY" v
  | none => OrbBin.PosixExt.unsetenvVar "ANTHROPIC_API_KEY"
  check (noKeyDoc.fieldBool? "has_api_key" == some false && noKeyDoc.fieldBool? "has_credentials" == some false &&
    !has noKeyDoc "sk-ant-instance-env-marker" && (noKeyDoc.fieldStr? "account_email").isNone)
    "member_added_account_never_inherits_instance_env_key"
  -- admin_sees_added_by_username
  let (_, aList) ← send "GET" "/api/ai/providers" admin (.obj #[]) app
  let aRow := ((aList.asArr?.getD #[]).find? (·.fieldStr? "id" == some probeId)).getD .null
  check (aRow.fieldStr? "created_by_username" == some "member" && !has aList secret) "admin_sees_added_by_username"
  -- member_reorder_shared_pool
  let (roSt, roDoc) ← send "POST" "/api/ai/providers/reorder" member (.obj #[("ids", .arr #[.str probeId, .str "prov-anth-1", .str "prov-anth-2"])]) app
  check (roSt == 200 && !has roDoc ownerName && !has roDoc secret) s!"member_reorder_shared_pool (got {roSt})"
  -- member_cannot_delete_owner_account
  let (delOwner, _) ← send "DELETE" "/api/ai/providers/prov-anth-1" member (.obj #[]) app
  check (delOwner == 403 && (← getAIProvider? store "prov-anth-1").isSome) s!"member_cannot_delete_owner_account (got {delOwner})"
  -- member_deletes_own_account
  let mut delOk := true
  for pid in #[probeId, (c4.fieldStr? "id").getD "", noKeyId] do
    let (dSt, _) ← send "DELETE" s!"/api/ai/providers/{pid}" member (.obj #[]) app
    delOk := delOk && dSt == 200 && (← getAIProvider? store pid).isNone
  check delOk "member_deletes_own_account"
  -- provider_audit_log_records_member_writes_without_values
  let (mAud, _) ← send "GET" "/api/ai/providers/audit" member (.obj #[]) app
  let (aAudSt, aud) ← send "GET" "/api/ai/providers/audit" admin (.obj #[]) app
  let entries := aud.asArr?.getD #[]
  let byMember (act : String) := entries.any (fun e => e.fieldStr? "user_id" == some "member" &&
    e.fieldStr? "username" == some "member" && e.fieldStr? "action" == some act)
  check (mAud == 403 && aAudSt == 200 && byMember "add" && byMember "edit" && byMember "delete" && byMember "reorder" &&
    entries.any (fun e => e.fieldStr? "provider_id" == some "prov-anth-1" && e.fieldStr? "action" == some "edit" &&
      (e.fieldArr? "fields").getD #[] == #[.str "name", .str "rpm_limit"]) &&
    !has aud secret && !has aud "ben-probe" && !has aud "member-renamed" && !has aud "api.example.com")
    s!"provider_audit_log_records_member_writes_without_values ({mAud},{aAudSt})"

/-- Replay an upgraded store: startup archives both databases, preserves typed
    evidence and all columns, leaves rows intact, and never rewrites the archive. -/
private def legacyBoardArchive (root : String) : IO Unit := do
  let path := root ++ "/legacy-board-export"
  let .ok old ← openCoreStore path | throw (IO.userError "archive fixture store")
  let sql (db : SqliteDb) (q : String) : IO Unit := do
    let .ok _ ← execParamQuery db q #[] | throw (IO.userError "archive fixture SQL")
  sql old.projectsDb "INSERT INTO project_tracks(project_slug,track,title) VALUES('legacy','track','retained title');"
  sql old.projectsDb "INSERT INTO project_decisions(id,slug,question,rationale) VALUES('d','legacy','question',NULL);"
  sql old.projectsDb "INSERT INTO project_steers(id,slug,body) VALUES('s','legacy','line one' || char(10) || 'line two');"
  sql old.projectsDb "INSERT INTO project_crons(slug,job_id) VALUES('legacy','job');"
  sql old.projectsDb "INSERT INTO controller_archives(slug,job_id) VALUES('legacy','job');"
  sql old.projectsDb "CREATE TABLE project_track_evidence(id TEXT, payload BLOB, weight INTEGER, note TEXT);"
  sql old.projectsDb "INSERT INTO project_track_evidence VALUES('e',x'00ff',7,NULL);"
  sql old.missionsDb "INSERT INTO mission_board_tasks(task_key,project_slug,track,mission_id) VALUES('task','legacy','track','mission');"
  let archive := System.FilePath.mk path / "archive"
  let marker := archive / "project-board-legacy.done"
  IO.FS.removeFile marker
  closeCoreStore old
  let .ok upgraded ← openCoreStore path | throw (IO.userError "archive upgrade startup")
  try
    let entries ← archive.readDir
    let some entry := entries.find? (fun e => e.fileName.endsWith ".jsonl")
      | throw (IO.userError "missing legacy archive")
    let bytes ← IO.FS.readFile entry.path
    let lines := (bytes.splitOn "\n").filter (!·.isEmpty)
    check (lines.length == 7) "archive includes every legacy row across both databases"
    let mut foundEvidence := false
    for line in lines do
      let .ok row := OrbBin.Json.parse line | throw (IO.userError "invalid archive JSONL")
      if row.fieldStr? "table" == some "project_track_evidence" then
        let payload := row.fieldOrNull "row"
        check (payload.fieldNat? "weight" == some 7 && payload.field? "note" == some .null &&
          (payload.fieldOrNull "payload").fieldStr? "$blob_hex" == some "00FF") "archive preserves numeric, null and blob evidence"
        foundEvidence := true
    check foundEvidence "archive discovers historical evidence tables"
    let fileStat ← OrbBin.PosixExt.statPath entry.path.toString
    check ((fileStat.mode &&& 0o777) == 0o600) "legacy archive is private"
    let .ok rows ← execParamQuery upgraded.projectsDb "SELECT title FROM project_tracks;" #[]
      | throw (IO.userError "legacy table disappeared")
    check (rows[1]? == some #["retained title"]) "archive never drops or changes old rows"
    sql upgraded.projectsDb "INSERT INTO project_steers(id,slug,body) VALUES('late','legacy','must not overwrite archive');"
    check ((← exportLegacyProjectBoard path upgraded.projectsDb upgraded.missionsDb).toOption == some 0) "archive marker prevents repeat export"
    check ((← IO.FS.readFile entry.path) == bytes) "one-shot archive stays unchanged"
    -- A failed filesystem write must not mark completion, and retry succeeds.
    let retryRoot := System.FilePath.mk path / "retry"
    IO.FS.createDirAll retryRoot
    IO.FS.writeFile (retryRoot / "archive") "blocked directory"
    check (!(← exportLegacyProjectBoard retryRoot.toString upgraded.projectsDb upgraded.missionsDb).isOk) "archive failure is reported"
    IO.FS.removeFile (retryRoot / "archive")
    check (!(← (retryRoot / "archive" / "project-board-legacy.done").pathExists)) "failed export has no marker"
    check ((← exportLegacyProjectBoard retryRoot.toString upgraded.projectsDb upgraded.missionsDb).toOption == some 8) "failed export retries all rows"
    -- Startup remains usable when the non-essential archive cannot be written.
    let startupRoot := System.FilePath.mk path / "archive-failure-startup"
    IO.FS.createDirAll startupRoot
    IO.FS.writeFile (startupRoot / "archive") "blocked directory"
    let .ok running ← openCoreStore startupRoot.toString
      | throw (IO.userError "archive failure must not abort startup")
    try
      let result ← execParamQuery running.projectsDb "SELECT 1;" #[]
      check result.isOk "archive failure leaves startup database handles usable"
    finally closeCoreStore running
    IO.FS.removeFile (startupRoot / "archive")
    check (!(← (startupRoot / "archive" / "project-board-legacy.done").pathExists)) "startup archive failure has no marker"
    let .ok retried ← openCoreStore startupRoot.toString
      | throw (IO.userError "archive retry startup")
    try
      check (← (startupRoot / "archive" / "project-board-legacy.done").pathExists) "next startup retries the failed archive"
    finally closeCoreStore retried
  finally closeCoreStore upgraded

/-- Two real stored principals through the REST/desktop and MCP HTTP boundary.
    All records, credentials and provider state are synthetic; no host effects. -/
def missionBoardFixtures (root : String) : IO Unit := do
  let .ok store ← openCoreStore (root ++ "/mission-board-fixtures") | throw (IO.userError "board fixture store")
  try
    let sql (db : SqliteDb) (q : String) (args : Array String := #[]) : IO Unit := do
      let .ok _ ← execParamQuery db q args | throw (IO.userError "board fixture SQL")
    let .ok () ← MissionBoard.initSchema store.missionsDb | throw (IO.userError "board schema")
    sql store.missionsDb "DELETE FROM mission_board_migrations;"
    sql store.missionsDb ("INSERT INTO missions(id,owner_user_id,project,parent_mission_id,tags) VALUES " ++
      "('root','a','orb',NULL,'[]'),('child','a','orb','root','[]')," ++
      "('sibling','a','orb','root','[]'),('foreign','b','evm-fast',NULL,'[]')," ++
      "('shared-child','a','orb','foreign','[]'),('btw','a','orb',NULL,'[\"btw-parent:child\"]');")
    sql store.projectsDb "INSERT INTO projects(slug,controller_mission_id) VALUES('orb','root'),('evm-fast','foreign');"
    let nearLimit := String.ofList (List.replicate 16380 'x') ++ "\r\n"
    let unicode := "  日本語 🦉 café é\r\n\n"
    for (slug, text) in #[("orb", nearLimit), ("evm-fast", unicode)] do
      sql store.projectsDb "INSERT INTO project_board(slug,text,updated_at) VALUES(?1,?2,'original');" #[slug, text]
    check (!(← MissionBoard.migrate store.missionsDb store.projectsDb "first" true).isOk)
      "Migration: interruption after committed copies, before completion marker"
    let rootReader : MissionBoard.Reader := { userId := "a", missionId := "root", role := "executor" }
    let childReader : MissionBoard.Reader := { rootReader with missionId := "child" }
    let first ← MissionBoard.read store.missionsDb rootReader "root"
    check ((first.toOption.bind (·.fieldStr? "text")).map String.toUTF8 == some nearLimit.toUTF8)
      "Migration: near-16KB orb fixture survives byte for byte"
    let foreign ← MissionBoard.read store.missionsDb { userId := "b" } "foreign"
    check ((foreign.toOption.bind (·.fieldStr? "text")).map String.toUTF8 == some unicode.toUTF8)
      "Migration: non-ASCII evm-fast fixture survives byte for byte"
    check ((first.toOption.bind (·.fieldStr? "updated_at")) == some "original") "Migration: timestamp preserved"
    check ((← MissionBoard.authorizeRead store.missionsDb childReader "root").isOk)
      "Authorization: descendant reads ancestor allowed"
    check (!(← MissionBoard.authorizeRead store.missionsDb rootReader "child").isOk)
      "Authorization: ancestor mission without a project role reads descendant denied"
    check (!(← MissionBoard.authorizeRead store.missionsDb childReader "sibling").isOk)
      "Authorization: sibling reads sibling denied"
    check (!(← MissionBoard.authorizeRead store.missionsDb { childReader with missionId := "shared-child" } "foreign").isOk)
      "Authorization: descendant of another owner's mission through a shared mission denied"
    check ((← MissionBoard.authorizeRead store.missionsDb { childReader with missionId := "btw" } "root").isOk)
      "Authorization: mixed btw/parent lineage at depth two allowed"
    let write (text time key : String) (fence : Option String := none) (interrupt : Bool := false) :=
      MissionBoard.write store.missionsDb rootReader "root" text time fence key "fixture-scope" key "write_mission_board" interrupt
    check ((← write "new board" "new-time" "w1").isOk) "Concurrency: transactional write succeeds"
    let oldBoard ← MissionBoard.read store.missionsDb rootReader "root"
    check (!(← write "rolled back" "rollback-time" "rollback-key" none true).isOk) "Concurrency: failure before commit is reported"
    check ((← MissionBoard.read store.missionsDb rootReader "root").toOption == oldBoard.toOption) "Concurrency: failed write retains old text and no receipt"
    check ((← MissionBoard.actionById? store.missionsDb "rollback-key").isNone) "Concurrency: failed write leaves no receipt"
    check ((← MissionBoard.migrate store.missionsDb store.projectsDb "retry").isOk) "Migration: retry completes marker"
    let newer ← MissionBoard.read store.missionsDb rootReader "root"
    check ((newer.toOption.bind (·.fieldStr? "text")) == some "new board") "Event order 5: migration replay preserves newer write"
    check ((← MissionBoard.migrate store.missionsDb store.projectsDb "third").isOk) "Migration: third run no-op"
    check ((← MissionBoard.read store.missionsDb rootReader "root").toOption == newer.toOption) "Migration: run twice same result"
    check (!(← write "conflicting" "later" "w2" (some "original")).isOk) "Concurrency: stale base_updated_at rejected"
    check ((← write "new board" "later" "w3").toOption.map (·.fieldOrNull "result") == newer.toOption) "Concurrency: identical rewrite preserves columns"
    check ((← write "different retry" "later" "w1").toOption.map (·.fieldOrNull "result") == newer.toOption) "Concurrency: settled key replay does not write"
    check ((← MissionBoard.actionById? store.missionsDb "w1").isSome) "Surface: get_action returns board receipt"
    check ((← MissionBoard.actionByKey? store.missionsDb "fixture-scope" "w1").isSome) "Concurrency: same key replays settled receipt"
    check (!(← write (String.ofList (List.replicate 8193 'é')) "later" "oversized").isOk) "Storage: UTF-8 byte cap rejects whole"
    for (uid, label, status) in #[("a", "owner user refused", 403), ("b", "member of another tenant zero-oracle", 404)] do
      let response ← MissionBoard.dispatchRest store.missionsDb store.projectsDb "PUT" "/api/control/missions/root/board" ByteArray.empty { userId := uid }
      check (response.map Prod.fst == some status) ("REST: " ++ label)
    check ((← MissionBoard.refuseUserWrite store.missionsDb "a" "root") == "not_mission_writer") "REST: admin refused without override"
    sql store.missionsDb "UPDATE missions SET project='new-project' WHERE id='root';"
    check ((← MissionBoard.read store.missionsDb rootReader "root").toOption == newer.toOption) "Event order 1: write then move preserves board"
    check ((← write "after move" "later" "w4").isOk) "Event order 2: move then write"
    let oldList ← MissionBoard.list store.missionsDb { userId := "a" } "orb"
    check ((oldList.toOption.bind (·.fieldArr? "boards")).getD #[] == #[]) "Event order 2: old project has no ghost"
    sql store.missionsDb "UPDATE missions SET status='acknowledged' WHERE id='root';"
    check ((← write "archived write" "latest" "w5").isOk) "Event order 4: archived mission still writable"
    sql store.missionsDb "UPDATE missions SET status='awaiting_user' WHERE id='root';"
    check (((← MissionBoard.read store.missionsDb rootReader "root").toOption.bind (·.fieldStr? "text")) == some "archived write")
      "Event order 4: resume retains archived write"
    sql store.missionsDb "DELETE FROM missions WHERE id='root';"
    let .ok deleted ← execParamQuery store.missionsDb "SELECT mission_id FROM mission_board WHERE mission_id='root';" #[]
      | throw (IO.userError "board deletion query")
    check (deleted.size == 1 && !(← write "late" "late" "late").isOk) "Event order 9: delete wins; no orphan or late write"
  finally closeCoreStore store

def run (root : String) : IO Unit := do
  missionBoardFixtures root
  legacyBoardArchive root
  let path := root ++ "/tenant-isolation"
  let .ok store ← openCoreStore path | throw (IO.userError "isolation store")
  let .ok mc ← openManagedComputeStore (path ++ "/managed_compute.db")
    | do closeCoreStore store; throw (IO.userError "isolation managed store")
  try
    let now : UInt64 := 1794564000
    let sql (db : SqliteDb) (query : String) (params : Array String := #[]) : IO Unit := do
      let .ok _ ← execParamQuery db query params | throw (IO.userError "isolation fixture SQL")
    for (uid, role) in #[("admin", "admin"), ("member", "member")] do
      sql store.missionsDb "INSERT INTO users(id,username,password_hash,role,unix_username) VALUES(?1,?1,'synthetic-hash',?2,?3);"
        #[uid, role, "orb-" ++ uid]
      let .ok () ← upsertMission store {
        id := uid ++ "-mission", ownerUserId := uid, title := uid ++ "-private-marker",
        status := "awaiting_user", backend := "codex", modelOverride := "",
        workingDirectory := path, project := uid ++ "-project", updatedAt := "2026-11-13T10:00:00Z" }
        | throw (IO.userError "isolation mission")
      sql store.projectsDb "INSERT INTO projects(slug,name,title,objective) VALUES(?1,?1,?1,?2);"
        #[uid ++ "-project", uid ++ "-private-marker"]
      sql store.projectsDb "INSERT INTO project_owners(slug,owner_user_id) VALUES(?1,?2);" #[uid ++ "-project", uid]
      sql store.missionsDb "INSERT INTO workspaces(id,name,path,owner_user_id) VALUES(?1,?1,?2,?3);"
        #[uid ++ "-workspace", path ++ "/" ++ uid ++ "-private-marker", uid]
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 10 }
    -- Pre-cutover rows are operator data, never implicitly shared with members.
    sql store.projectsDb "INSERT INTO projects(slug,name,objective) VALUES('legacy-project','admin-private-marker-legacy','legacy owner data');"
    let .ok () ← saveManagedFleetConfig mc true true 5000 0 10 | throw (IO.userError "isolation fleet")
    let .ok _ ← provisionManagedMachine mc fleet {
      id := "legacy-machine", sandboxName := "admin-private-marker-legacy", ownerUserId := "",
      ownerKind := "user", spentCents := 0 } now | throw (IO.userError "isolation legacy machine")
    for uid in #["admin", "member"] do
      let .ok _ ← provisionManagedMachine mc fleet {
        id := uid ++ "-machine", sandboxName := uid ++ "-private-marker", ownerUserId := uid,
        ownerKind := "user", spentCents := 0 } now | throw (IO.userError "isolation machine")
      let .ok () ← addUserSpendCents store uid (currentUtcDay now) 0 (if uid == "admin" then 73 else 2)
        | throw (IO.userError "isolation usage")
    sql mc.db "CREATE TABLE IF NOT EXISTS managed_snapshots (id TEXT PRIMARY KEY,name TEXT NOT NULL,provider TEXT NOT NULL DEFAULT 'boat',source_machine_id TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'ready',size_gb INTEGER NOT NULL DEFAULT 20,created_at TEXT NOT NULL DEFAULT '');"
    for uid in #["admin", "member", "legacy"] do
      sql mc.db "INSERT INTO managed_snapshots(id,name,source_machine_id) VALUES(?1,?2,?3);"
        #[uid ++ "-snapshot", (if uid == "member" then "member" else "admin") ++ "-private-marker-snapshot", uid ++ "-machine"]
    let .ok loadedFleet ← loadManagedFleet mc true true 5000 0 10 | throw (IO.userError "isolation fleet load")
    let st : CoreAppState := {
      cfg := { instanceName := "dev", jwtSecret := "synthetic-isolation-jwt-not-a-live-secret", workingDir := path },
      store := store, managedStore? := some mc, bootstrapAdminId := "admin", searchIdx? := none,
      managedProvisioningOverride? := some (OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat",
        { coreUrl := "https://unused.invalid", script := "" }),
      managedRef := ← IO.mkRef loadedFleet, chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1 }
    let token (uid role : String) := mintSessionTokenV2 st.cfg.jwtSecret uid role 1 (now + 3600)
    let member := token "member" "member"
    let admin := token "admin" "admin"
    let send (method target bearer : String) (body : JVal := .obj #[]) (app : CoreAppState := st) : IO (Nat × JVal) := do
      let payload := renderCompact body
      let wire := s!"{method} {target} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {bearer}\r\nContent-Type: application/json\r\nContent-Length: {payload.utf8ByteSize}\r\n\r\n{payload}"
      let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "isolation request")
      let .ok response ← dispatchCoreRequest app request now | throw (IO.userError "isolation dispatch")
      return (response.status, (parseBytes response.body).toOption.getD .null)
    -- Per-user Library contract: real HTTP dispatch and local fixture git only.
    let previousLibraryPath ← IO.getEnv "LIBRARY_PATH"
    let ownerLibrary := path ++ "/owner-library"
    OrbBin.PosixExt.setenvVar "LIBRARY_PATH" ownerLibrary
    try
      let putSkill (dir name : String) : IO Unit := do
        let dest := System.FilePath.mk dir / "skill" / name
        IO.FS.createDirAll dest
        IO.FS.writeFile (dest / "SKILL.md") s!"---\nname: {name}\ndescription: {name} private body\n---\n{name} instructions\n"
      let memberLibrary := path ++ "/library/users/member"
      putSkill ownerLibrary "owner-only-skill"
      putSkill memberLibrary "member-only-skill"
      -- 1. Catalogs, including descriptions, are disjoint and owner-independent.
      let (_, ownerPlan) ← send "GET" "/api/library/skill-delivery" admin
      let (_, memberPlan) ← send "GET" "/api/library/skill-delivery" member
      check (((renderCompact ownerPlan).splitOn "owner-only-skill").length > 1 &&
        ((renderCompact ownerPlan).splitOn "member-only-skill").length == 1 &&
        ((renderCompact memberPlan).splitOn "owner-only-skill").length == 1 &&
        ((renderCompact memberPlan).splitOn "member-only-skill").length > 1) "library 1: disjoint catalogs"
      putSkill ownerLibrary "owner-added-later"
      check ((← send "GET" "/api/library/skill-delivery" member).2 == memberPlan) "library 1: byte-stable member plan"
      let putContext (slug name : String) : IO Unit := do
        let dir := System.FilePath.mk path / "project-files" / slug / "skills" / name
        IO.FS.createDirAll dir
        IO.FS.writeFile (dir / "SKILL.md") name
      putContext "same-project" "owner-context-only"
      putContext "member:same-project" "member-context-only"
      let (contextCode, contextPlan) ← send "GET" "/api/library/skill-delivery?project=same-project" member
      check (contextCode == 200 && ((renderCompact contextPlan).splitOn "owner-context-only").length == 1 &&
        ((renderCompact contextPlan).splitOn "member-context-only").length > 1) "member project context stays scoped"
      let .ok () ← writeSettingsJson path (.obj #[("library_remote", .str "/owner-private-remote")])
        | throw (IO.userError "library settings fixture")
      let globalBefore ← IO.FS.readFile (System.FilePath.mk path / "settings.json")
      check ((← send "PUT" "/api/settings/library-remote" member
        (.obj #[("library_remote", .str ownerLibrary)])).1 == 400)
        "member cannot clone the host owner's private checkout as a local remote"
      sql store.missionsDb "INSERT INTO users(id,username,password_hash,role,unix_username) VALUES('library-admin','library-admin','synthetic-hash','admin','orb-library-admin');"
      let anotherAdmin := token "library-admin" "admin"
      let (_, anotherPlan) ← send "GET" "/api/library/skill-delivery" anotherAdmin
      check (anotherPlan.fieldArr? "skills" == some #[]) "non-bootstrap admin has own empty Library"
      let (_, anotherSettings) ← send "GET" "/api/settings" anotherAdmin
      check (anotherSettings.fieldOrNull "library_remote" == .null &&
        anotherSettings.fieldOrNull "library_revision" == .null) "non-bootstrap admin cannot read owner Library settings"
      sql store.missionsDb "DELETE FROM users WHERE id='library-admin';"
      -- 4. Connect a private fixture remote; only library.json may change.
      let fixture := path ++ "/fixture-library"
      putSkill fixture "fixture-member-skill"
      let git (args : Array String) : IO Unit := do
        let output ← IO.Process.output { cmd := "git", args := args, cwd := some (System.FilePath.mk fixture) }
        check (output.exitCode == 0) "library fixture git"
      git #["init", "-b", "main"]
      git #["add", "skill"]
      git #["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "commit", "-m", "fixture"]
      let (remoteStatus, _) ← send "PUT" "/api/settings/library-remote" member
        (.obj #[("library_remote", .str fixture)])
      check (remoteStatus == 200 && (← IO.FS.readFile (System.FilePath.mk path / "settings.json")) == globalBefore)
        "library 4: member remote leaves global settings byte-identical"
      let .ok memberSettings := parse (← IO.FS.readFile (System.FilePath.mk memberLibrary / "library.json"))
        | throw (IO.userError "library member metadata")
      check (memberSettings.fieldStr? "remote" == some fixture) "library 4: private remote persisted"
      let (_, fixtureRevision) ← do
        let output ← IO.Process.output { cmd := "git", args := #["rev-parse", "HEAD"], cwd := some (System.FilePath.mk fixture) }
        pure (output.exitCode, output.stdout.trimAscii.toString)
      check ((← send "PUT" "/api/settings/library-revision" member
        (.obj #[("library_revision", .str fixtureRevision)])).1 == 200) "member revision pin"
      -- 2. Status returns own remote and revision, and hides the member path.
      let (statusCode, status) ← send "GET" "/api/library/status" member
      check (statusCode == 200 && status.fieldStr? "path" == some "" && status.fieldStr? "remote" == some fixture && status.fieldStr? "revision" == some fixtureRevision)
        "library 2: scoped member status"
      check ((← send "PUT" "/api/settings/library-revision" member
        (.obj #[("library_revision", .null)])).1 == 200) "member clears revision pin"
      -- 3. Sync writes only the member checkout, retaining its local settings.
      let ownerBefore ← IO.FS.readFile (System.FilePath.mk ownerLibrary / "skill/owner-only-skill/SKILL.md")
      IO.FS.removeDirAll (System.FilePath.mk memberLibrary / ".git")
      IO.FS.removeDirAll (System.FilePath.mk memberLibrary / "skill/fixture-member-skill")
      let (syncCode, syncStatus) ← send "POST" "/api/library/sync" member
      check (syncCode == 200 && syncStatus.fieldStr? "path" == some "" &&
        (← (System.FilePath.mk memberLibrary / "skill/fixture-member-skill/SKILL.md").pathExists) &&
        (← IO.FS.readFile (System.FilePath.mk ownerLibrary / "skill/owner-only-skill/SKILL.md")) == ownerBefore)
        "library 3: member sync isolated"
      -- 5. Remote delivery reads the mission owner, never LIBRARY_PATH for a member.
      let prelude ← OrbCore.Skills.remoteInstallPrelude path none "codex" path "member" "admin"
      check ((prelude.splitOn "owner-only-skill").length == 1 && (prelude.splitOn "member-only-skill").length > 1)
        "library 5: member remote install"
      let .ok () ← upsertMission store {
        id := "library-mission", ownerUserId := "member",
        title := "library fixture", status := "awaiting_user", backend := "opencode", modelOverride := "",
        workingDirectory := path, updatedAt := "2026-11-14T00:00:00Z" }
        | throw (IO.userError "library mission fixture")
      let installWorkspace := System.FilePath.mk path / "member-installed-workspace"
      IO.FS.createDirAll installWorkspace
      let installed ← IO.Process.output { cmd := "/bin/sh", args := #["-c", prelude], cwd := some installWorkspace }
      check (installed.exitCode == 0 &&
        (← (installWorkspace / ".agents/skills/member-only-skill/SKILL.md").pathExists) &&
        !(← (installWorkspace / ".agents/skills/owner-only-skill/SKILL.md").pathExists))
        "library 5: actual member workspace contains only member skills"
      -- 6. Coordinator steers another owner's mission; selection follows the mission.
      sql store.missionsDb "INSERT INTO mission_shares(mission_id,user_id,granted_by) VALUES('library-mission','admin','member');"
      let (steerCode, _) ← send "POST" "/api/control/message" admin
        (.obj #[("mission_id", .str "library-mission"), ("content", .str "/skill:member-only-skill continue")])
      check (steerCode == 200) "library 6: coordinator selects member mission skills"
      let .ok turn ← OrbCore.RemoteDispatch.bindRemoteTurnOwner store (some mc)
        { missionId := "library-mission", targetNodeId := "dedicated", backend := "codex", prompt := "coordinator turn" }
        "dedicated" #[{ id := "dedicated", baseUrl := "https://unused.invalid", tokenEnv := "SYNTHETIC_UNUSED_NODE_TOKEN" }]
        | throw (IO.userError "library 6: dispatch ownership")
      let coordinatedPrelude ← OrbCore.Skills.remoteInstallPrelude path none turn.backend path turn.ownerUserId "admin"
      check (turn.ownerUserId == "member" && coordinatedPrelude == prelude)
        "library 6: coordinator installs byte-identical member prelude"
      let coordinatedWorkspace := System.FilePath.mk path / "coordinated-member-workspace"
      IO.FS.createDirAll coordinatedWorkspace
      let coordinatedInstall ← IO.Process.output { cmd := "/bin/sh", args := #["-c", coordinatedPrelude], cwd := some coordinatedWorkspace }
      check (coordinatedInstall.exitCode == 0 &&
        (← (coordinatedWorkspace / ".agents/skills/member-only-skill/SKILL.md").pathExists) &&
        !(← (coordinatedWorkspace / ".agents/skills/owner-only-skill/SKILL.md").pathExists))
        "library 6: coordinated workspace contains member skills only"
      let (foreignCode, _) ← send "POST" "/api/control/message" admin
        (.obj #[("mission_id", .str "library-mission"), ("content", .str "/skill:owner-only-skill continue")])
      check (foreignCode == 400) "library 6: coordinator cannot select owner skill for member"
      sql store.missionsDb "DELETE FROM mission_shares WHERE mission_id='library-mission' AND user_id='admin';"
      sql store.missionsDb "DELETE FROM mission_events WHERE mission_id='library-mission';"
      sql store.missionsDb "DELETE FROM remote_message_queue WHERE mission_id='library-mission';"
      sql store.missionsDb "DELETE FROM missions WHERE id='library-mission';"
      -- 7. The legacy owner resolver and global remote remain authoritative.
      check ((← OrbCore.Skills.resolveLibraryRootFor "admin" path path "admin") == ownerLibrary &&
        (← OrbCore.Skills.resolveLibraryRoot path path) == ownerLibrary &&
        (← OrbCore.ResourcesAndSystem.resolveEffectiveLibraryRemote path "") == "/owner-private-remote")
        "library 7: owner path and settings unchanged"
      -- 8. Invalid IDs are explicit errors, even without /skill: references.
      let invalid ← OrbCore.Skills.buildDeliveryPlan path none path "../admin" "admin"
      check (match invalid with | .error e => e == "library_invalid_user_scope" | _ => false)
        "library 8: reject invalid user scope"
      let invalidRoute ← OrbCore.ResourcesAndSystem.handleLibraryRoute store path "" false "GET"
        ["api", "library", "status"] #[] #[] ByteArray.empty "../admin" "admin"
      check (match invalidRoute with
        | some (code, _, body) => code == 400 && ((String.fromUTF8? body |>.getD "").splitOn "library_invalid_user_scope").length > 1
        | none => false) "library 8: route rejects invalid ID before resolution"
      for bad in #["..", ".", "a/b", "a:b", "user..other", String.ofList (List.replicate 65 'a')] do
        check (!(OrbCore.Skills.validLibraryScope bad "admin")) "library 8: unsafe scope"
      -- Members can create, edit, read and delete their own skill via plural alias.
      for method in #["POST", "PUT"] do
        check ((← send method "/api/library/skills/member-created" member
          (.obj #[("content", .str "member created content")])).1 == 200) "member Library create/edit"
      check ((← send "GET" "/api/library/skills/member-created" member).1 == 200) "member Library read"
      check ((← send "GET" "/api/library/skills/member-created" admin).1 == 404) "owner cannot read member skill"
      check ((← send "DELETE" "/api/library/skills/member-created" member).1 == 200) "member Library delete"
    finally
      match previousLibraryPath with
      | some value => OrbBin.PosixExt.setenvVar "LIBRARY_PATH" value
      | none => OrbBin.PosixExt.unsetenvVar "LIBRARY_PATH"
    let call (bearer tool : String) (args : JVal := .obj #[]) : IO JVal := do
      let (status, doc) ← send "POST" "/api/mcp/call" bearer (.obj #[("name", .str tool), ("arguments", args)])
      check (status == 200) s!"MCP transport {tool}"
      return doc
    let configured := { st with cfg := { st.cfg with usersJson := "{\"member\":\"configured-member-password-123\"}" } }
    let (legacyStatus, _) ← send "GET" "/api/auth/me" "configured-member-password-123" (.obj #[]) configured
    check (legacyStatus == 401) "configured raw password as bearer is rejected (SEC-02)"
    let (legacyForeign, _) ← send "GET" "/api/control/missions/admin-mission" "configured-member-password-123" (.obj #[]) configured
    check (legacyForeign == 401) "configured raw password bearer rejected on REST"
    let ambiguous := { configured with cfg := { configured.cfg with
      usersJson := "{\"admin\":\"configured-member-password-123\",\"member\":\"configured-member-password-123\"}" } }
    check ((← send "GET" "/api/auth/me" "configured-member-password-123" (.obj #[]) ambiguous).1 == 401)
      "ambiguous configured passwords fail closed"
    -- REST retry receipts have the same tenant boundary as their MCP equivalents.
    for (bearer, uid) in #[(admin, "admin"), (member, "member")] do
      let body : JVal := .obj #[("id", .str (uid ++ "-retry-mission")), ("title", .str "retry fixture"),
        ("placement", .str "client"), ("idempotency_key", .str "same-rest-key-two-users")]
      let (status, created) ← send "POST" "/api/control/missions" bearer body
      check (status == 201 && created.fieldStr? "id" == some (uid ++ "-retry-mission")) "REST retry receipt stays with caller"
      let (repeatedStatus, repeated) ← send "POST" "/api/control/missions" bearer body
      check (repeatedStatus == 201 && repeated == created) "REST own retry stays idempotent"
    let foreign : JVal := .obj #[("mission_id", .str "admin-mission"), ("id", .str "admin-mission"),
      ("message", .str "attempted mutation"), ("prompt", .str "attempted wakeup"), ("delay_seconds", .nat 60),
      ("role", .str "operator"), ("user_id", .str "admin"), ("owner_user_id", .str "admin")]
    -- The desktop uses these same REST paths. Neither list nor guessed ids disclose admin data.
    for target in #["/api/control/missions", "/api/projects", "/api/workspaces", "/api/managed-machines"] do
      let (status, doc) ← send "GET" target member
      check (status == 200 && ((renderCompact doc).splitOn "admin-private-marker").length == 1) s!"REST list {target}"
    for method in #["GET", "PATCH", "DELETE"] do
      let (status, _) ← send method "/api/control/missions/admin-mission" member
      check (status == 404) s!"REST guessed foreign mission {method}"
    -- Conversation search (`/api/control/missions/search/messages`) vs per-mission `/api/control/missions/:id/messages`.
    for (mid, txt) in #[("admin-mission", "shared-search-token admin-private-search-body"),
        ("member-mission", "shared-search-token member-own-search-body")] do
      let .ok _ ← appendMissionEvent store mid "user_message"
        (renderCompact (.obj #[("content", .str txt)])) "2026-11-13T10:01:00Z"
        | throw (IO.userError "isolation search message fixture")
      sql store.missionsDb "UPDATE mission_events SET content=?2 WHERE mission_id=?1;" #[mid, txt]
    let (ownMsgSt, ownMsgDoc) ← send "GET" "/api/control/missions/member-mission/messages" member
    let ownMsgs := ownMsgDoc.asArr?.getD #[]
    let cOk := ownMsgSt == 200 && ownMsgs.size == 1 &&
      ((renderCompact ownMsgDoc).splitOn "member-own-search-body").length > 1
    let (mSearchSt, mSearchDoc) ← send "GET" "/api/control/missions/search/messages?q=shared-search-token" member
    let mSearchHits := (mSearchDoc.fieldArr? "hits").getD #[]
    let aOk := mSearchSt == 200 &&
      (mSearchDoc.fieldArr? "hits").isSome &&
      mSearchDoc.field? "next_cursor" == some .null &&
      ((mSearchDoc.field? "coverage").bind JVal.asObj?).isSome
    let dOk := mSearchHits.size == 1 &&
      (mSearchHits[0]?.bind (·.fieldStr? "mission_id")) == some "member-mission" &&
      ((renderCompact mSearchDoc).splitOn "admin-mission").length == 1 &&
      ((renderCompact mSearchDoc).splitOn "admin-private-search-body").length == 1 &&
      ((renderCompact mSearchDoc).splitOn "admin-private-marker").length == 1
    let legacyUnscopedApp := { st with bootstrapAdminId := "", cfg := { st.cfg with devMode := true } }
    let (admSearchSt, admSearchDoc) ← send "GET" "/api/control/missions/search/messages?q=shared-search-token" admin (.obj #[]) st
    let (legSearchSt, legSearchDoc) ← send "GET" "/api/control/missions/search/messages?q=shared-search-token" "" (.obj #[]) legacyUnscopedApp
    let bAdminOk := admSearchSt == 200 &&
      admSearchDoc.asArr?.isNone &&
      (admSearchDoc.fieldArr? "hits").isSome &&
      admSearchDoc.field? "next_cursor" == some .null &&
      ((admSearchDoc.field? "coverage").bind JVal.asObj?).isSome
    let bLegacyOk := legSearchSt == 200 &&
      legSearchDoc.asArr?.isNone &&
      (legSearchDoc.fieldArr? "hits").isSome &&
      legSearchDoc.field? "next_cursor" == some .null &&
      ((legSearchDoc.field? "coverage").bind JVal.asObj?).isSome
    check (aOk && bAdminOk && bLegacyOk && cOk && dOk)
      (s!"search/messages contract: " ++
       s!"(a) member={aOk} (st={mSearchSt}, body={renderCompact mSearchDoc}); " ++
       s!"(b) admin={bAdminOk} (st={admSearchSt}, body={renderCompact admSearchDoc}), legacy={bLegacyOk} (st={legSearchSt}, body={renderCompact legSearchDoc}); " ++
       s!"(c) ownMessages={cOk} (st={ownMsgSt}, count={ownMsgs.size}); " ++
       s!"(d) memberIsolated={dOk} (hits={renderCompact (.arr mSearchHits)})")
    for target in #["/api/bitwarden/status", "/api/secrets", "/api/admin/users"] do
      check ((← send "GET" target member).1 == 403) s!"REST admin boundary {target}"
    for method in #["GET", "POST"] do
      let target := if method == "GET" then "/api/managed-machines/admin-machine" else "/api/managed-machines/admin-machine/stop"
      check ((← send method target member).1 == 404) "REST foreign machine read/action"
    check ((← send "GET" "/api/managed-machines/member-machine" member).1 == 200) "REST own machine"
    for target in #["/api/managed-machines/legacy-machine", "/api/managed-machines/legacy-machine/operations"] do
      check ((← send "GET" target member).1 == 404) "unowned legacy machine is operator-only"
    check ((← send "POST" "/api/managed-machines/legacy-machine/stop" member).1 == 404)
      "unowned legacy machine cannot be controlled by member"
    -- Denials happen before provider lookup, mutation or any vault/network I/O.
    let (snapStatus, snaps) ← send "GET" "/api/managed-machines/snapshots" member
    check (snapStatus == 200 && ((renderCompact snaps).splitOn "admin-private-marker").length == 1 &&
      ((renderCompact snaps).splitOn "member-snapshot").length > 1) "REST snapshot inventory has verified ownership"
    check ((← send "POST" "/api/managed-machines/snapshots" member
      (.obj #[("machine_id", .str "admin-machine"), ("name", .str "unauthorized-snapshot")])).1 == 404)
      "foreign snapshot creation denied before provider"
    for sid in #["admin-snapshot", "legacy-snapshot", "absent-snapshot"] do
      check ((← send "DELETE" ("/api/managed-machines/snapshots/" ++ sid) member).1 == 404)
        "foreign or unowned snapshot deletion denied before provider"
    let .ok snapshots ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_snapshots;" #[]
      | throw (IO.userError "isolation snapshot verification")
    check ((snapshots[1]?.bind (·[0]?)) == some "3") "denied snapshot operations leave fixtures intact"
    let (_, memberSettings) ← send "GET" "/api/managed-machines/settings" member
    check (memberSettings.fieldNat? "spent_today_cents" == some 2) "REST settings never disclose fleet usage to a member"
    for target in #["/api/managed-machines/providers/boat", "/api/managed-machines/settings"] do
      check ((← send "PUT" target member).1 == 403) s!"REST provider mutation {target}"
    -- Member dashboard bearer used to become an unconstrained MCP operator.
    for tool in #["get_mission", "get_mission_events", "get_mission_health", "get_mission_diagnostics",
        "list_mission_shared_files", "get_budget", "get_consult_result", "get_cloud_execution",
        "send_message_to_mission", "cancel_mission", "resume_mission", "update_mission_settings", "schedule_wakeup"] do
      let doc ← call member tool foreign
      check (doc.fieldBool? "ok" == some false && (doc.fieldOrNull "error").fieldStr? "code" == some "not_found")
        s!"MCP foreign mission {tool}"
    for tool in #["list_missions", "list_active_missions", "list_projects", "list_workspaces"] do
      let doc ← call member tool
      check (doc.fieldBool? "ok" == some true && ((renderCompact doc).splitOn "admin-private-marker").length == 1 &&
        ((renderCompact doc).splitOn "admin-mission").length == 1 && ((renderCompact doc).splitOn "admin-project").length == 1 &&
        ((renderCompact doc).splitOn "admin-workspace").length == 1) s!"MCP scoped list {tool}"
    let machines ← call member "list_managed_machines"
    let machineResult := machines.fieldOrNull "result"
    check (machines.fieldBool? "ok" == some true &&
      ((renderCompact machineResult).splitOn "admin-machine").length == 1 &&
      ((renderCompact machineResult).splitOn "member-machine").length > 1 &&
      machineResult.fieldNat? "spent_today_cents" == some 2) "MCP machine inventory and usage stay with member"
    let budget ← call member "get_budget"
    check ((budget.fieldOrNull "result").fieldNat? "spent_today_cents" == some 2) "MCP budget excludes admin spend"
    let projectArgs : JVal := .obj #[("project", .str "admin-project"), ("status", .str "archived")]
    for tool in #["get_project", "get_project_grant", "update_project_status"] do
      let doc ← call member tool projectArgs
      check (doc.fieldBool? "ok" == some false) s!"MCP foreign project {tool}"
    for tool in #["secret_list", "secret_get", "secret_request", "secret_put", "secret_delete", "secret_move", "list_privileged_access"] do
      let doc ← call member tool (.obj #[("name", .str "SYNTHETIC_DENIED_PROBE")])
      check (doc.fieldBool? "ok" == some false) s!"MCP member cannot use owner broker {tool}"
    -- Choosing a more powerful role at session minting must not change tenant ownership.
    let mut memberSession := ""
    for role in #["executor", "coordinator", "operator"] do
      let (status, minted) ← send "POST" "/api/mcp/session" member
        (.obj #[("mission_id", .str "member-mission"), ("role", .str role)])
      let scopedToken := (minted.fieldStr? "token").getD ""
      if role == "executor" then memberSession := scopedToken
      check (status == 200 && !scopedToken.isEmpty) s!"session mint {role}"
      for tool in #["get_mission", "get_mission_events", "cancel_mission", "schedule_wakeup"] do
        let doc ← call scopedToken tool foreign
        check (doc.fieldBool? "ok" == some false) s!"scoped role cannot cross tenant {role}/{tool}"
      for tool in #["secret_list", "secret_get", "secret_request", "secret_put", "secret_delete", "secret_move"] do
        let doc ← call scopedToken tool (.obj #[("name", .str "SYNTHETIC_DENIED_PROBE")])
        check (doc.fieldBool? "ok" == some false &&
          (doc.fieldOrNull "error").fieldStr? "code" == some "forbidden")
          s!"scoped role cannot use owner secret broker {role}/{tool}"
    -- Project board contract: owner nomination, controller-only mutation, shared reads.
    let emptyBoard ← call memberSession "read_project_board"
    check (emptyBoard.fieldBool? "ok" == some true &&
      (emptyBoard.fieldOrNull "result").fieldStr? "text" == some "") "board starts empty"
    let boardText : JVal := .obj #[("text", .str "controller plan")]
    let deniedBoard ← call memberSession "write_project_board" boardText
    check (deniedBoard.fieldBool? "ok" == some false &&
      (deniedBoard.fieldOrNull "error").fieldStr? "message" == some "not_project_controller") "non-controller cannot write board"
    let (nominateStatus, _) ← send "PUT" "/api/projects/member-project/controller-mission" member
      (.obj #[("mission_id", .str "member-mission")])
    check (nominateStatus == 200) "owner sets project controller"
    let writtenBoard ← call memberSession "write_project_board" boardText
    check (writtenBoard.fieldBool? "ok" == some true &&
      (writtenBoard.fieldOrNull "result").fieldStr? "updated_by_mission_id" == some "member-mission") "controller writes board"
    for tool in #["write_project_board", "write_mission_board"] do
      let args := boardText.setField "idempotency_key" (.str ("receipt-parity-" ++ tool))
      let first ← call memberSession tool args
      let receipt := first.fieldOrNull "result"
      let aid := (receipt.fieldStr? "action_id").getD ""
      check (!aid.isEmpty && receipt.fieldStr? "state" == some "succeeded" &&
        receipt.fieldStr? "status" == some "completed" && receipt.fieldStr? "accepted" == some "yes" &&
        (receipt.fieldOrNull "result").fieldStr? "text" == some "controller plan") s!"{tool} settled receipt shape"
      let fetched ← call memberSession "get_action" (.obj #[("action_id", .str aid)])
      let replay ← call memberSession tool args
      check (first == fetched && first == replay) s!"{tool} first/get_action/retry equality"
      let foreignReceipt ← call admin "get_action" (.obj #[("action_id", .str aid)])
      check (foreignReceipt.fieldBool? "ok" == some false &&
        (foreignReceipt.fieldOrNull "error").fieldStr? "code" == some "not_found" &&
        !(renderCompact foreignReceipt).contains '🦉') s!"{tool} foreign tenant receipt not_found"
      let .ok stored ← execParamQuery store.missionsDb
          "SELECT result FROM mission_board_actions WHERE id=?1;" #[aid]
        | throw (IO.userError "board receipt query")
      let raw := (OrbBin.Json.parse (stored[1]![0]?.getD "")).toOption.getD .null
      check (raw == receipt.fieldOrNull "result" && (raw.field? "action_id").isNone)
        s!"{tool} stores raw payload"
    for (bearer, target) in #[(member, "admin-mission"), (admin, "member-mission")] do
      let (status, denied) ← send "GET" s!"/api/control/missions/{target}/board" bearer .null
      check (status == 404 && denied.fieldStr? "error" == some "mission_not_found" &&
        (denied.field? "text").isNone && (denied.field? "updated_at").isNone &&
        (denied.field? "text_sha256").isNone) "B2_REST_foreign_board_read_zero_oracle"
      let denied ← call bearer "read_mission_board" (.obj #[("mission_id", .str target)])
      check (denied.fieldBool? "ok" == some false &&
        (denied.fieldOrNull "error").fieldStr? "code" == some "not_found" &&
        (denied.field? "result").isNone) "B2_MCP_foreign_board_read_zero_oracle"
    let .ok () ← upsertMission store {
      id := "board-reader", ownerUserId := "member", title := "board reader", parentMissionId := "member-mission",
      status := "awaiting_user", backend := "codex", modelOverride := "", workingDirectory := path,
      project := "member-project", updatedAt := "2026-11-13T10:00:00Z" }
      | throw (IO.userError "board reader fixture")
    let (_, readerSession) ← send "POST" "/api/mcp/session" member
      (.obj #[("mission_id", .str "board-reader"), ("role", .str "executor")])
    let readerToken := (readerSession.fieldStr? "token").getD ""
    let readBoard ← call readerToken "read_project_board"
    check ((readBoard.fieldOrNull "result").fieldStr? "text" == some "controller plan") "second project mission reads board"
    check ((← call readerToken "write_project_board" boardText).fieldBool? "ok" == some false) "reader cannot overwrite board"
    let oversized : JVal := .obj #[("text", .str (String.ofList (List.replicate 8193 'é')))]
    let tooLarge ← call memberSession "write_project_board" oversized
    check ((tooLarge.fieldOrNull "error").fieldStr? "code" == some "board_too_large") "MCP board byte cap"
    check ((← send "PUT" "/api/projects/member-project/board" member oversized).1 == 403) "REST alias refuses user writer"
    for method in #["GET", "PUT"] do
      check ((← send method "/api/projects/admin-project/board" member boardText).1 == 404) "foreign board is not found"
    check ((← send "PUT" "/api/projects/member-project/controller-mission" member
      (.obj #[("mission_id", .str "admin-mission")])).1 == 404) "controller must belong to project"
    let (_, projectBoardDetail) ← send "GET" "/api/projects/member-project" member
    check (projectBoardDetail.fieldStr? "controller_mission_id" == some "member-mission" &&
      (projectBoardDetail.fieldStr? "board_updated_at").isSome) "project detail includes board metadata"
    check ((← send "PUT" "/api/projects/member-project/controller-mission" member
      (.obj #[("mission_id", .null)])).1 == 200) "owner clears controller"
    let createdController ← call memberSession "start_mission"
      (.obj #[("title", .str "successor controller"), ("controller", .bool true),
        ("remote_node_id", .str "managed-member-machine")])
    let successorId := (createdController.fieldOrNull "result").fieldStr? "mission_id" |>.getD ""
    check (createdController.fieldBool? "ok" == some true && !successorId.isEmpty) s!"MCP start_mission accepts controller: {renderCompact createdController}"
    let (_, successorBoard) ← send "GET" "/api/projects/member-project/board" member
    check (successorBoard.fieldStr? "controller_mission_id" == some successorId) "MCP creation nominates controller"
    let (oldBoardStatus, retainedBoard) ← send "GET" "/api/control/missions/member-mission/board" member .null
    check (successorBoard.fieldStr? "text" == some "" &&
      successorBoard.fieldOrNull "updated_at" == .null && oldBoardStatus == 200 &&
      retainedBoard.fieldStr? "text" == some "controller plan") "B2_controller_replacement_preserves_old_board_new_empty"
    let (restControllerStatus, restController) ← send "POST" "/api/control/missions" member
      (.obj #[("title", .str "REST controller"), ("backend", .str "codex"),
        ("project", .str "member-project"), ("placement", .str "client"), ("controller", .bool true)])
    check (restControllerStatus == 201) s!"REST creation accepts controller: {restControllerStatus} {renderCompact restController}"
    let (_, restBoard) ← send "GET" "/api/projects/member-project/board" member
    check (restBoard.fieldStr? "controller_mission_id" == restController.fieldStr? "id") "REST creation nominates controller"
    -- Existing project ownership is authoritative even if its slug uses the caller's namespace.
    sql store.missionsDb "INSERT INTO users(id,username,password_hash,role,unix_username) VALUES('other-member','other-member','synthetic-hash','member','orb-other-member');"
    for slug in #["member:controller-owned-by-a", "other-member:controller-owned-by-a"] do
      sql store.projectsDb "INSERT INTO projects(slug,name,controller_mission_id) VALUES(?1,'owned by A','a-controller');" #[slug]
      sql store.projectsDb "INSERT INTO project_owners(slug,owner_user_id) VALUES(?1,'other-member');" #[slug]
    for slug in #["controller-owned-by-a", "member:controller-owned-by-a", "other-member:controller-owned-by-a"] do
      let (status, rejected) ← send "POST" "/api/control/missions" member
        (.obj #[("title", .str "forbidden controller nomination"), ("backend", .str "codex"),
          ("project", .str slug), ("placement", .str "client"), ("controller", .bool true)])
      check (status == 404 && rejected.fieldStr? "error" == some "not_found")
        s!"REST controller creation requires existing project owner: {slug} {status} {renderCompact rejected}"
    let .ok unchangedControllers ← execParamQuery store.projectsDb
      "SELECT controller_mission_id FROM projects WHERE slug IN ('member:controller-owned-by-a','other-member:controller-owned-by-a');" #[]
      | throw (IO.userError "REST controller ownership verification")
    check (unchangedControllers.size == 3 && (unchangedControllers.extract 1 3).all (· == #["a-controller"]))
      "member B cannot replace member A's controller using raw or scoped slugs"
    let .ok deniedMissions ← execParamQuery store.missionsDb
      "SELECT COUNT(*) FROM missions WHERE title='forbidden controller nomination';" #[]
      | throw (IO.userError "REST controller rejected mission verification")
    check (deniedMissions[1]? == some #["0"]) "controller ownership denial precedes mission creation"
    sql store.projectsDb "DELETE FROM project_owners WHERE slug IN ('member:controller-owned-by-a','other-member:controller-owned-by-a');"
    sql store.projectsDb "DELETE FROM projects WHERE slug IN ('member:controller-owned-by-a','other-member:controller-owned-by-a');"
    sql store.missionsDb "DELETE FROM users WHERE id='other-member';"
    -- Members can request the plan's dev-only pass for their OWN mission. It
    -- still requires a separately approved live lease and never exposes host
    -- audit or generic privilege tokens. Dashboard role labels cannot redeem it.
    let requested ← call memberSession "request_privileged_access" (.obj #[("scope", .str "dev_operator"),
      ("reason", .str "synthetic approval test"), ("ttl_minutes", .nat 30)])
    check (requested.fieldBool? "ok" == some true && (requested.fieldOrNull "result").fieldStr? "state" == some "pending")
      "member mission can request a dev pass without bypassing approval"
    let devArgs : JVal := .obj #[("grant_id", .str "member-dev-grant")]
    check ((← call memberSession "get_dev_access" devArgs).fieldBool? "ok" == some false)
      "dev access denied before approval"
    for uid in #["admin", "member"] do
      let .ok () ← upsertPrivilegeLease store {
        grantId := uid ++ "-dev-grant", leaseToken := "synthetic-" ++ uid ++ "-dev-pass",
        missionId := uid ++ "-mission", scope := "dev_operator", targetHost := "dev", expiresAtEpoch := now + 1800 }
        | throw (IO.userError "isolation approved dev lease fixture")
    let devAccess ← call memberSession "get_dev_access" devArgs
    check (devAccess.fieldBool? "ok" == some true && (devAccess.fieldOrNull "result").fieldStr? "instance" == some "dev")
      "member mission may redeem its own approved dev pass"
    check ((← call member "get_dev_access" devArgs).fieldBool? "ok" == some false)
      "direct member cannot take a mission's approved pass"
    check ((← call memberSession "get_dev_access" (devArgs.setField "grant_id" (.str "admin-dev-grant"))).fieldBool? "ok" == some false)
      "member mission cannot redeem the admin mission's approved pass"
    let ownGrants ← call memberSession "list_privileged_access"
    check (ownGrants.fieldBool? "ok" == some true &&
      ((renderCompact ownGrants).splitOn "admin-dev-grant").length == 1 &&
      ((renderCompact ownGrants).splitOn "lease_token").length == 1 &&
      ((ownGrants.fieldOrNull "result").field? "command_audit").isNone)
      "member grant listing contains only dev grant metadata for its own mission"
    let (externalStatus, externalDoc) ← send "POST" "/api/mcp/external-sessions" member
      (.obj #[("role", .str "coordinator")])
    let externalToken := (externalDoc.fieldStr? "token").getD ""
    check (externalStatus == 200 && !externalToken.isEmpty) "external member session minted"
    check ((← call externalToken "get_mission" foreign).fieldBool? "ok" == some false)
      "external coordinator remains tenant scoped"
    -- Dashboard callers share a transport session id, never a retry-key namespace.
    let wakeArgs := foreign.setField "idempotency_key" (.str "same-key-two-users")
    let adminWake ← call admin "schedule_wakeup" wakeArgs
    let adminAction := ((adminWake.fieldOrNull "result").fieldStr? "action_id").getD ""
    check (!adminAction.isEmpty) "admin wakeup positive control"
    let memberArgs := wakeArgs.setField "mission_id" (.str "member-mission") |>.setField "id" (.str "member-mission")
    let memberWake ← call member "schedule_wakeup" memberArgs
    let memberResult := memberWake.fieldOrNull "result"
    let memberAction := (memberResult.fieldStr? "action_id").getD ""
    check (!memberAction.isEmpty && memberAction != adminAction && memberResult.fieldStr? "mission_id" == some "member-mission")
      "retry keys cannot replay another user's action result"
    let repeated ← call member "schedule_wakeup" memberArgs
    check ((repeated.fieldOrNull "result").fieldStr? "action_id" == some memberAction) "own retry remains idempotent"
    for tool in #["get_action", "cancel_action"] do
      let doc ← call member tool (.obj #[("action_id", .str adminAction)])
      check (((renderCompact doc).splitOn "admin-mission").length == 1 &&
        (doc.fieldBool? "ok" == some false || (doc.fieldOrNull "result").fieldBool? "cancelled" == some false))
        s!"foreign action receipt {tool}"
    let waits ← call member "wait_actions" (.obj #[("action_ids", .arr #[.str adminAction])])
    check (((renderCompact waits).splitOn "admin-mission").length == 1 &&
      (waits.fieldOrNull "result").fieldBool? "all_succeeded" == some false) "wait cannot disclose or confirm foreign action"
    let memory ← call member "memory_get_knowledge_tree"
    check (memory.fieldBool? "ok" == some false &&
      (memory.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "member is denied before the owner's personal memory broker"
    -- A member who cannot see a mission cannot delete its queued follow-up (`404`, row unchanged).
    let (enqAdminQueueStatus, _) ← send "POST" "/api/control/queue" admin
      (.obj #[("id", .str "admin-queue-item"), ("mission_id", .str "admin-mission"),
        ("content", .str "admin-queued-followup"), ("source", .str "desktop")])
    check (enqAdminQueueStatus == 201) "admin queue enqueue positive control"
    let (memberDelForeignQueueStatus, _) ← send "DELETE" "/api/control/queue/admin-queue-item" member
    check (memberDelForeignQueueStatus == 404) "member cannot delete foreign mission queue item"
    let .ok foreignQueueRows ← execParamQuery store.missionsDb
      "SELECT state,COALESCE(phase,0),json_extract(payload,'$.message.content') FROM remote_message_queue WHERE user_id='core' AND message_id='admin-queue-item';" #[]
      | throw (IO.userError "isolation foreign queue verification")
    check (foreignQueueRows[1]? == some #["waiting", "0", "admin-queued-followup"])
      "foreign mission queue row survives denied member DELETE"
    -- A role chosen for a shared admin mission must not adopt the admin's identity.
    sql store.missionsDb "INSERT INTO mission_shares(mission_id,user_id,granted_by) VALUES('admin-mission','member','admin');"
    let (sharedStatus, sharedDoc) ← send "POST" "/api/mcp/session" member
      (.obj #[("mission_id", .str "admin-mission"), ("role", .str "operator")])
    let sharedToken := (sharedDoc.fieldStr? "token").getD ""
    check (sharedStatus == 200 && !sharedToken.isEmpty) "shared session minted"
    -- A same-name owned project must not authorize access to a shared mission's foreign board.
    sql store.projectsDb "INSERT INTO projects(slug,name) VALUES('member:admin-project','shadow');"
    sql store.projectsDb "INSERT INTO project_owners(slug,owner_user_id) VALUES('member:admin-project','member');"
    sql store.projectsDb "UPDATE projects SET controller_mission_id='admin-mission' WHERE slug='admin-project';"
    sql store.projectsDb "INSERT INTO project_board(slug,text,updated_at) VALUES('admin-project','private-admin-board','now');"
    for tool in #["read_project_board", "write_project_board"] do
      let collision ← call sharedToken tool (.obj #[("text", .str "unauthorized")])
      check ((collision.fieldOrNull "error").fieldStr? "code" == some "not_found" &&
        ((renderCompact collision).splitOn "private-admin-board").length == 1) "same-name project cannot authorize foreign board"
    let .ok boardRows ← execParamQuery store.projectsDb "SELECT text FROM project_board WHERE slug='admin-project';" #[]
      | throw (IO.userError "board collision verification")
    check (boardRows[1]? == some #["private-admin-board"]) "foreign board survives same-name project write"
    sql store.projectsDb "DELETE FROM project_owners WHERE slug='member:admin-project';"
    sql store.projectsDb "DELETE FROM projects WHERE slug='member:admin-project';"
    check ((← call sharedToken "get_mission" foreign).fieldBool? "ok" == some true) "participant may read shared mission"
    check ((← call sharedToken "resume_mission" foreign).fieldBool? "ok" == some false)
      "shared session cannot acquire owner mutation rights"
    check ((← call sharedToken "secret_list").fieldBool? "ok" == some false)
      "shared admin mission does not grant its owner's secret authority"
    check ((← call sharedToken "get_dev_access" (devArgs.setField "grant_id" (.str "admin-dev-grant"))).fieldBool? "ok" == some false)
      "shared admin mission does not delegate its owner's approved dev pass"
    let sharedMemory ← call sharedToken "memory_get_knowledge_tree"
    check ((sharedMemory.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "shared admin mission does not grant its owner's personal memory"
    -- A missionless coordinator session is its stored issuer: the administrator's is admin,
    -- a member's is not, and a token with no stored row stays anonymous.
    let missionless (sid : String) : String :=
      let claims : McpSessionClaims :=
        { sessionId := sid, missionId := "", role := "coordinator", project := "",
          isExternal := false, expiresAt := 9999999999, hardExpiresAt := 9999999999 }
      mintScopedMcpToken st.cfg.jwtSecret claims
    sql store.projectsDb "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('missionless-admin','admin','',9999999999,0,'mission');"
    sql store.projectsDb "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('missionless-member','member','',9999999999,0,'mission');"
    let adminOk ← call (missionless "missionless-admin") "list_cloud_accounts"
    let memberDenied ← call (missionless "missionless-member") "list_cloud_accounts"
    let rowlessDenied ← call (missionless "missionless-rowless") "list_cloud_accounts"
    check ((adminOk.fieldOrNull "error").fieldStr? "message" != some "Administrator required")
      s!"the administrator's missionless session keeps owner tools: {renderCompact adminOk}"
    check ((memberDenied.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "a member's missionless session gets no owner tools"
    check ((rowlessDenied.fieldOrNull "error").fieldStr? "message" == some "Administrator required")
      "a missionless token with no stored session stays anonymous"
    sql store.projectsDb "DELETE FROM mcp_sessions_v1 WHERE id IN ('missionless-admin','missionless-member');"
    -- Rows the owner stored under a legacy token subject move to the administrator once that
    -- token is verified; a subject that names a real user is never adopted.
    sql store.projectsDb "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('legacy-alias-session','legacy-prod','',9999999999,0,'external_session');"
    sql store.projectsDb "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('member-owned-session','member','',9999999999,0,'external_session');"
    adoptLegacyOwnerAlias store "legacy-prod" "admin"
    adoptLegacyOwnerAlias store "member" "admin"
    adoptLegacyOwnerAlias store "" "admin"
    let ownerOf (sid : String) : IO String := do
      let .ok rows ← execParamQuery store.projectsDb "SELECT owner FROM mcp_sessions_v1 WHERE id=?1;" #[sid]
        | throw (IO.userError "legacy alias lookup")
      pure ((rows[1]?.bind (·[0]?)).getD "?")
    check ((← ownerOf "legacy-alias-session") == "admin") "a verified legacy subject's sessions become the administrator's"
    check ((← ownerOf "member-owned-session") == "member") "a real user's sessions are never adopted"
    sql store.projectsDb "DELETE FROM mcp_sessions_v1 WHERE id IN ('legacy-alias-session','member-owned-session');"
    let ownProject ← call member "get_project" (.obj #[("project", .str "member-project")])
    check (ownProject.fieldBool? "ok" == some true) "member retains own project access"
    sql store.projectsDb "INSERT INTO project_bindings(slug,control_session_id) VALUES('admin-project','admin-session');"
    let (_, hiddenBinding) ← send "GET" "/api/projects/by-session/admin-session" member
    check ((hiddenBinding.field? "slug").getD .null == .null) "project session binding cannot disclose another user's project"
    let (_, ownBinding) ← send "GET" "/api/projects/by-session/admin-session" admin
    check (ownBinding.fieldStr? "slug" == some "admin-project") "owner retains project session binding"
    for suffix in #["controller", "controller/action", "crons", "crons/defaults", "crons/admin-job", "crons/admin-job/action", "tasks", "decision", "tracks", "task-board"] do
      for method in #["GET", "POST", "PATCH", "DELETE"] do
        let (code, body) ← send method ("/api/projects/admin-project/" ++ suffix) member
        if method == "GET" && suffix == "controller" then
          check (code == 200 && body == .obj #[("job", .null)]) "empty controller compatibility response"
        else if method == "GET" && suffix == "crons" then
          check (code == 200 && body == .obj #[("jobs", .arr #[])]) "empty crons compatibility response"
        else
          check (code == 410 && body.fieldStr? "error" == some "removed") "removed routes disclose no tenant data"
    sql store.projectsDb "INSERT INTO mcp_actions_v1(id,scope,retry_key,tool,state,result) VALUES('retired-action','00000000-0000-4000-8000-000000000000::user:admin:plan_tasks','old-key','plan_tasks','succeeded','{\"old\":true}');"
    let retiredReplay ← call admin "plan_tasks" (.obj #[("idempotency_key", .str "old-key")])
    check ((retiredReplay.fieldOrNull "error").fieldStr? "code" == some "unknown_tool") "retired tools cannot replay an old success receipt"
    for tool in #["get_situation", "set_project_track", "add_project_steer", "record_project_decision", "plan_tasks", "board_status"] do
      let response ← call admin tool (.obj #[])
      check ((response.fieldOrNull "error").fieldStr? "code" == some "unknown_tool") "removed MCP tools return tool-not-found"
    -- No prompt is supplied: a bad placement must fail even for an inert MCP
    -- create, before any machine rental, credential minting or job submission.
    for node in #["agent-core", "sepolia", "managed-admin-machine", "managed-legacy-machine"] do
      let denied ← call member "start_mission" (.obj #[("title", .str "denied placement"), ("remote_node_id", .str node)])
      check (denied.fieldBool? "ok" == some false) s!"MCP cannot bypass placement authority: {node}"
    let some memberRecord ← getUserById? store "member" | throw (IO.userError "member fixture disappeared")
    let nodes : Array OrbCore.RemoteFleetAndRelay.StaticRemoteNode := #[{
      id := "dedicated", baseUrl := "https://unused.invalid", tokenEnv := "SYNTHETIC_UNUSED_NODE_TOKEN" }]
    let remoteSpec : OrbCore.RemoteDispatch.RemoteTurnSpec := {
      missionId := "member-mission", targetNodeId := "dedicated", backend := "codex", prompt := "synthetic" }
    let .ok owned ← OrbCore.RemoteDispatch.bindRemoteTurnOwner store (some mc) remoteSpec "dedicated" nodes
      | throw (IO.userError "valid member remote placement rejected")
    check (owned.ownerUserId == "member") "omitted dispatch owner is restored before minting any credentials"
    check (!(← OrbCore.RemoteDispatch.bindRemoteTurnOwner store (some mc)
      { remoteSpec with ownerUserId := "admin" } "dedicated" nodes).isOk) "dispatch cannot spoof another owner"
    check (!(← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc)
      { memberRecord with unixUsername? := none } "dedicated" nodes).isOk) "member needs a stored Linux identity"
    check (!(← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc) memberRecord "dedicated"
      (nodes.map (fun n => { n with labels := #["control-plane"] }))).isOk) "control-plane node labels are authoritative"
    check ((← OrbCore.RemoteDispatch.authorizeRemotePlacement (some mc) memberRecord "managed-member-machine" nodes).isOk)
      "member may use its own managed VM"
    for tool in #["list_cloud_accounts", "list_mission_access"] do
      check ((← call member tool).fieldBool? "ok" == some false) "direct member cannot enumerate owner account/grant metadata"
    check ((← call sharedToken "list_mission_access").fieldBool? "ok" == some false)
      "shared mission cannot disclose the owner's mission grants"
    let own ← call member "get_mission" (.obj #[("mission_id", .str "member-mission")])
    check (own.fieldBool? "ok" == some true) "member retains own mission access"
    let adm ← call admin "get_mission" foreign
    check (adm.fieldBool? "ok" == some true) "admin retains own mission access"
    let some unchanged ← getMission? store "admin-mission" | throw (IO.userError "admin mission disappeared")
    check (unchanged.status == "awaiting_user" && unchanged.title == "admin-private-marker") "denied operations have no effects"
    -- Hydrated provider routes must project anonymous type labels and quota windows for members
    -- while preserving full account identity for admins.
    let provNameMarker := "admin-provider-name-marker-alpha"
    let provEmailMarker := "admin-provider-email-marker@example.com"
    let provBaseUrlMarker := "https://admin-provider-baseurl-marker.internal/v1"
    let provGoogleProjMarker := "admin-google-project-marker-999"
    let provOrgMarker := "admin-org-marker-corp"
    let provOrgIdMarker := "org-admin-marker-777"
    let provEnvMarker := "ANTHROPIC_API_KEY"
    let .ok () ← upsertAIProvider store {
      id := "prov-anth-1", providerType := "anthropic", name := provNameMarker,
      enabled := true, baseUrl := provBaseUrlMarker, apiKey := "sk-ant-secret-key-marker-1",
      rpmLimit? := some 4321, maxConcurrency? := some 17,
      customModels := #[{ id := "custom-claude", name? := some "Custom Claude", rpmLimit? := some 60, tpmLimit? := some 120000, maxConcurrency? := some 4 }],
      updatedAt := "2026-11-13T10:00:00Z" }
      | throw (IO.userError "isolation provider 1")
    let .ok () ← upsertAIProvider store {
      id := "prov-anth-2", providerType := "anthropic", name := "admin-provider-name-marker-beta",
      enabled := true, baseUrl := provBaseUrlMarker, apiKey := "sk-ant-secret-key-marker-2",
      updatedAt := "2026-11-13T10:00:00Z" }
      | throw (IO.userError "isolation provider 2")
    let hydratedJson : JVal := .arr #[
      .obj #[
        ("id", .str "prov-anth-1"),
        ("provider_type", .str "anthropic"),
        ("name", .str provNameMarker),
        ("enabled", .bool true),
        ("base_url", .str provBaseUrlMarker),
        ("account_email", .str provEmailMarker),
        ("google_project_id", .str provGoogleProjMarker),
        ("priority", .nat 7)
      ],
      .obj #[
        ("id", .str "prov-anth-2"),
        ("provider_type", .str "anthropic"),
        ("name", .str "admin-provider-name-marker-beta"),
        ("enabled", .bool true),
        ("base_url", .str provBaseUrlMarker),
        ("account_email", .str provEmailMarker),
        ("google_project_id", .str provGoogleProjMarker),
        ("priority", .nat 8)
      ]
    ]
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedJson)
    let pHub ← newProviderRuntimeHub
    let mkUsagePayload (pName : String) : JVal := .obj #[
      ("provider_type", .str "anthropic"),
      ("provider_name", .str pName),
      ("account_email", .str provEmailMarker),
      ("account_name", .str provNameMarker),
      ("organization", .str provOrgMarker),
      ("organization_id", .str provOrgIdMarker),
      ("status", .str "connected"),
      ("unified_5h_utilization", .num "0.42"),
      ("optimize", .obj #[
        ("as_of", .str "2026-11-13T10:00:00Z"),
        ("primary_window", .str "5h"),
        ("windows", .arr #[.obj #[("key", .str "5h"), ("label", .str "5-hour"), ("pct_used", .num "42"), ("pct_remaining", .nat 58)]])
      ])
    ]
    let nowReal ← OrbBin.PosixExt.nowEpoch
    pHub.mu.atomically do
      let cur ← get
      set { cur with
        usageEntries := #[
          { providerId := "prov-anth-1", fetchedSec := nowReal, fetchedIso := "2026-11-13T10:00:00Z", payload := mkUsagePayload provNameMarker },
          { providerId := "prov-anth-2", fetchedSec := nowReal, fetchedIso := "2026-11-13T10:00:00Z", payload := mkUsagePayload "admin-provider-name-marker-beta" }
        ]
      }
    let stWithProviders := { st with providerHub? := some pHub }
    let (_, adminProvDetailUsage) ← send "GET" "/api/ai/providers/prov-anth-1/usage" admin (.obj #[]) stWithProviders
    let (_, adminProvList) ← send "GET" "/api/ai/providers" admin (.obj #[]) stWithProviders
    let (_, adminProvDetail) ← send "GET" "/api/ai/providers/prov-anth-1" admin (.obj #[]) stWithProviders
    let (_, adminProvUsage) ← send "GET" "/api/ai/providers/usage" admin (.obj #[]) stWithProviders
    let (_, adminForBackend) ← send "GET" "/api/ai/providers/for-backend/claudecode" admin (.obj #[]) stWithProviders
    let adminCombined := renderCompact (.arr #[adminProvList, adminProvDetail, adminProvUsage, adminProvDetailUsage, adminForBackend])
    for marker in #[provNameMarker, provEmailMarker, provBaseUrlMarker, provGoogleProjMarker, provOrgMarker, provOrgIdMarker, provEnvMarker] do
      check ((adminCombined.splitOn marker).length > 1) s!"admin sees provider marker {marker}"
    let mut routeLeaks : Array String := #[]
    for (routeName, target) in #[
        ("GET /api/ai/providers", "/api/ai/providers"),
        ("GET /api/ai/providers/:id", "/api/ai/providers/prov-anth-1"),
        ("GET /api/ai/providers/usage", "/api/ai/providers/usage"),
        ("GET /api/ai/providers/:id/usage", "/api/ai/providers/prov-anth-1/usage"),
        ("GET /api/ai/providers/for-backend/claudecode", "/api/ai/providers/for-backend/claudecode"),
        ("GET /api/ai/providers/cli-proxy-login", "/api/ai/providers/cli-proxy-login"),
        ("GET /api/ai/providers/:id/auth/methods", "/api/ai/providers/prov-anth-1/auth/methods"),
        ("GET /api/ai/providers/types", "/api/ai/providers/types")] do
      let (mStatus, mDoc) ← send "GET" target member (.obj #[]) stWithProviders
      let raw := renderCompact mDoc
      check (mStatus == 200) s!"member status 200 on {routeName}"
      let routeMarkers :=
        if target == "/api/ai/providers/types" ||
           target == "/api/ai/providers/cli-proxy-login" ||
           target == "/api/ai/providers/prov-anth-1/auth/methods" then
          #[provNameMarker, "admin-provider-name-marker-beta", provEmailMarker, provBaseUrlMarker,
            provGoogleProjMarker, provOrgMarker, provOrgIdMarker, "4321", "sk-ant-secret"]
        else
          #[provNameMarker, "admin-provider-name-marker-beta", provEmailMarker, provBaseUrlMarker,
            provGoogleProjMarker, provOrgMarker, provOrgIdMarker, provEnvMarker, "4321", "sk-ant-secret"]
      let mut leakedOnRoute : Array String := #[]
      for marker in routeMarkers do
        if (raw.splitOn marker).length > 1 then
          leakedOnRoute := leakedOnRoute.push marker
      if !leakedOnRoute.isEmpty then
        let joinedMarkers := String.intercalate ", " leakedOnRoute.toList
        routeLeaks := routeLeaks.push s!"{routeName} -> [{joinedMarkers}]"
    let joinedLeaks := String.intercalate "; " routeLeaks.toList
    check routeLeaks.isEmpty s!"member provider routes leaked owner identity: {joinedLeaks}"
    let (cliLoginPostSt, _) ← send "POST" "/api/ai/providers/cli-proxy-login" member
      (.obj #[("provider", .str "anthropic")]) stWithProviders
    check (cliLoginPostSt != 403) s!"member may start a subscription login (POST /api/ai/providers/cli-proxy-login got {cliLoginPostSt})"
    let (_, memberListDoc) ← send "GET" "/api/ai/providers" member (.obj #[]) stWithProviders
    let memberRows := match memberListDoc with | .arr xs => xs | _ => #[]
    let mRow1 := memberRows[0]?.getD .null
    let mRow2 := memberRows[1]?.getD .null
    check (mRow1.fieldStr? "id" == some "prov-anth-1" && mRow1.fieldStr? "name" == some "Anthropic 1" &&
      mRow2.fieldStr? "id" == some "prov-anth-2" && mRow2.fieldStr? "name" == some "Anthropic 2" &&
      (mRow1.field? "account_email").isNone && ((mRow1.fieldOrNull "status").field? "account").isNone &&
      (mRow1.field? "base_url").isNone && (mRow1.field? "google_project_id").isNone &&
      (mRow1.field? "env_var").isNone && (mRow1.field? "rpm_limit").isNone &&
      (mRow1.field? "max_concurrency").isNone && (mRow1.field? "priority").isNone)
      "member provider row keeps only projected fields and indexed type display name"
    let (_, memberDetailDoc) ← send "GET" "/api/ai/providers/prov-anth-1" member (.obj #[]) stWithProviders
    check (memberDetailDoc.fieldStr? "id" == some "prov-anth-1" &&
      memberDetailDoc.fieldStr? "name" == some "Anthropic 1" &&
      (memberDetailDoc.field? "account_email").isNone &&
      ((memberDetailDoc.fieldOrNull "status").field? "account").isNone)
      "member provider detail uses unified member projection"
    let (_, memberUsageDoc) ← send "GET" "/api/ai/providers/prov-anth-1/usage" member (.obj #[]) stWithProviders
    check (memberUsageDoc.fieldStr? "status" == some "connected" &&
      (memberUsageDoc.field? "unified_5h_utilization").isSome &&
      (((memberUsageDoc.fieldOrNull "optimize").fieldArr? "windows").getD #[]).size == 1 &&
      (memberUsageDoc.field? "account_email").isNone &&
      (memberUsageDoc.field? "organization").isNone &&
      (memberUsageDoc.field? "organization_id").isNone)
      "member provider usage keeps quota windows without account identity"
    -- Closed key allowlist on member provider row responses (GET list, GET detail, PUT preference)
    -- and admin positive control.
    let allowedRowKeys : Array String := #[
      "id", "name", "provider_type", "provider_type_name",
      "enabled", "globally_enabled", "user_enabled", "effective_enabled",
      "has_credentials", "has_api_key", "has_oauth", "uses_oauth",
      "status", "custom_models", "added_by_me"
    ]
    let allowedStatusKeys : Array String := #["type", "message"]
    let allowedModelKeys : Array String := #["id", "name", "context_limit", "output_limit"]
    let objKeys (jv : JVal) : Array String :=
      match jv with | .obj kvs => kvs.map Prod.fst | _ => #[]
    let diffExactKeys (actual expected : Array String) : Option String :=
      match actual.find? (fun k => !expected.contains k) with
      | some extra => some s!"unexpected key `{extra}`"
      | none =>
        match expected.find? (fun k => !actual.contains k) with
        | some missing => some s!"missing key `{missing}`"
        | none => none
    let diffSubsetKeys (actual allowed : Array String) : Option String :=
      (actual.find? (fun k => !allowed.contains k)).map (fun extra => s!"unexpected key `{extra}`")
    let checkHydratedMemberRowKeys (ctx : String) (row : JVal) : IO Unit := do
      if let some bad := diffExactKeys (objKeys row) allowedRowKeys then
        check false s!"{ctx} top-level key allowlist violation: {bad}"
      if let some bad := diffExactKeys (objKeys (row.fieldOrNull "status")) allowedStatusKeys then
        check false s!"{ctx} status key allowlist violation: {bad}"
      for cm in (row.fieldArr? "custom_models").getD #[] do
        if let some bad := diffSubsetKeys (objKeys cm) allowedModelKeys then
          check false s!"{ctx} custom_models key allowlist violation: {bad}"
    check (!memberRows.isEmpty) "member GET /api/ai/providers returned rows"
    for idx in [0:memberRows.size] do
      checkHydratedMemberRowKeys s!"member GET /api/ai/providers[{idx}]" memberRows[idx]!
    checkHydratedMemberRowKeys "member GET /api/ai/providers/prov-anth-1" memberDetailDoc
    let (prefOffSt, prefOffDoc) ← send "PUT" "/api/ai/providers/prov-anth-1/preference" member
      (.obj #[("enabled", .bool false)]) stWithProviders
    check (prefOffSt == 200) s!"member PUT /api/ai/providers/prov-anth-1/preference disable status 200 (got {prefOffSt})"
    if let some bad := diffSubsetKeys (objKeys prefOffDoc) allowedRowKeys then
      check false s!"member PUT /api/ai/providers/prov-anth-1/preference top-level key allowlist violation: {bad}"
    if let some bad := diffSubsetKeys (objKeys (prefOffDoc.fieldOrNull "status")) allowedStatusKeys then
      check false s!"member PUT /api/ai/providers/prov-anth-1/preference status key allowlist violation: {bad}"
    for cm in (prefOffDoc.fieldArr? "custom_models").getD #[] do
      if let some bad := diffSubsetKeys (objKeys cm) allowedModelKeys then
        check false s!"member PUT /api/ai/providers/prov-anth-1/preference custom_models key allowlist violation: {bad}"
    let prefOffRaw := renderCompact prefOffDoc
    for marker in #[provNameMarker, "admin-provider-name-marker-beta", provEmailMarker, provBaseUrlMarker,
        provGoogleProjMarker, provOrgMarker, provOrgIdMarker, provEnvMarker, "4321", "sk-ant-secret"] do
      check ((prefOffRaw.splitOn marker).length == 1)
        s!"member PUT /api/ai/providers/prov-anth-1/preference leaked marker {marker}"
    check (prefOffDoc.fieldBool? "user_enabled" == some false)
      "member PUT /api/ai/providers/prov-anth-1/preference sets user_enabled == false"
    let (prefOnSt, prefOnDoc) ← send "PUT" "/api/ai/providers/prov-anth-1/preference" member
      (.obj #[("enabled", .bool true)]) stWithProviders
    check (prefOnSt == 200 && prefOnDoc.fieldBool? "user_enabled" == some true)
      "member PUT /api/ai/providers/prov-anth-1/preference restores user_enabled == true"
    let adminRows := match adminProvList with | .arr xs => xs | _ => #[]
    let adminExtraKeys := adminRows.foldl (fun acc r =>
      acc ++ (objKeys r).filter (fun k => !allowedRowKeys.contains k)) #[]
    check (!adminExtraKeys.isEmpty && adminExtraKeys.contains "account_email" && adminExtraKeys.contains "base_url")
      "admin GET /api/ai/providers positive control retains admin-only keys outside member allowlist"
    -- `/api/model-routing/health*` must never expose sidecar auth file names or emails to any role.
    let .ok () ← upsertAIProvider store {
      id := "iso-claude-oauth", providerType := "anthropic", name := "Owner Personal Claude",
      enabled := true, apiKey := "cli-proxy-managed"
    } | throw (IO.userError "isolation oauth provider")
    let (scFd, scPort) ← IO.ofExcept (← LeanSys.Posix.tcpListen "127.0.0.1" 0 8)
    let priorScBase ← IO.getEnv "CLAUDE_CODE_PROXY_BASE_URL"
    let priorScKey ← IO.getEnv "CLI_PROXY_MANAGEMENT_KEY"
    OrbBin.PosixExt.setenvVar "CLAUDE_CODE_PROXY_BASE_URL" s!"http://127.0.0.1:{scPort}"
    OrbBin.PosixExt.setenvVar "CLI_PROXY_MANAGEMENT_KEY" "fixture-isolation-mgmt"
    let scStop ← IO.mkRef false
    let scBody := "{\"files\":[{\"name\":\"claude-owner-secret.json\",\"provider\":\"claude\",\"email\":\"owner-secret@example.com\",\"disabled\":false,\"status\":\"error\",\"cooldowns\":[{\"scope\":\"credential\",\"reason\":\"credential_quota\",\"retry_at\":\"2026-11-14T00:00:00Z\",\"remaining_seconds\":7200}]}]}"
    let hydratedWithOauth : JVal := .arr ((hydratedJson.asArr?.getD #[]).push (.obj #[
      ("id", .str "iso-claude-oauth"),
      ("provider_type", .str "anthropic"),
      ("name", .str "Owner Personal Claude"),
      ("enabled", .bool true),
      ("account_email", .str "owner-secret@example.com"),
      ("oauth", .obj #[("access_token", .str "fixture-only-no-live-access")])
    ]))
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedWithOauth)
    let scTask ← IO.asTask (prio := .dedicated) do
      while !(← scStop.get) do
        match ← LeanSys.Posix.tcpAcceptPoll scFd 50 with
        | .ok client =>
          discard <| LeanSys.Posix.readStreamChunk client 8192
          discard <| LeanSys.Posix.writeAll client
            s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {scBody.utf8ByteSize}\r\nConnection: close\r\n\r\n{scBody}".toUTF8
          discard <| LeanSys.Posix.closeFd client
        | .error _ => pure ()
    try
      for (roleLbl, bearer) in #[("admin", admin), ("member", member)] do
        let (hSt, hDoc) ← send "GET" "/api/model-routing/health" bearer (.obj #[]) stWithProviders
        let hRaw := renderCompact hDoc
        let hRow := ((hDoc.asArr?.getD #[]).find? (fun v => v.fieldStr? "account_id" == some "iso-claude-oauth")).getD .null
        check (hSt == 200 &&
          hRow.fieldUInt64? "cooldown_secs_remaining" == some 7200 &&
          hRow.fieldStr? "parked_until" == some "2026-11-14T00:00:00Z" &&
          hRow.fieldStr? "parked_reason" == some "credential_quota" &&
          (hRaw.splitOn "claude-owner-secret.json").length == 1 &&
          (hRaw.splitOn "owner-secret@example.com").length == 1 &&
          (hRaw.splitOn provEmailMarker).length == 1)
          s!"model-routing health exposes parked state without file name or email ({roleLbl})"
      check ((← send "POST" "/api/model-routing/health/iso-claude-oauth/clear" member (.obj #[]) stWithProviders).1 == 403)
        "member cannot clear model-routing health"
    finally
      IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedJson)
      scStop.set true
      discard <| IO.wait scTask
      discard <| LeanSys.Posix.closeFd scFd
      match priorScBase with
      | some v => OrbBin.PosixExt.setenvVar "CLAUDE_CODE_PROXY_BASE_URL" v
      | none => OrbBin.PosixExt.unsetenvVar "CLAUDE_CODE_PROXY_BASE_URL"
      match priorScKey with
      | some v => OrbBin.PosixExt.setenvVar "CLI_PROXY_MANAGEMENT_KEY" v
      | none => OrbBin.PosixExt.unsetenvVar "CLI_PROXY_MANAGEMENT_KEY"
    -- Delete `iso-claude-oauth` from SQLite so subsequent checks see the two baseline active providers.
    sql store.missionsDb "DELETE FROM ai_providers WHERE id='iso-claude-oauth';" #[]
    memberSharedProviderRules (fun m t b body app => send m t b body app) member admin stWithProviders store provNameMarker
    -- Sibling provider/AI/model-routing GET routes must not leak admin provider names,
    -- disabled admin provider rows, discovery labels, or global proxy usage/outcome rows to members,
    -- while returning 200 reduced views to members and leaving admin/legacy-unscoped responses unchanged.
    let disabledProvMarker := "admin-disabled-prov-marker"
    let .ok () ← upsertAIProvider store {
      id := disabledProvMarker, providerType := "openai", name := disabledProvMarker,
      enabled := false, apiKey := ""
    } | throw (IO.userError "isolation disabled provider")
    let hydratedWithDisabled : JVal := .arr ((hydratedJson.asArr?.getD #[]).push (.obj #[
      ("id", .str disabledProvMarker),
      ("provider_type", .str "openai"),
      ("name", .str disabledProvMarker),
      ("enabled", .bool false),
      ("account_email", .str provEmailMarker),
      ("priority", .nat 9)
    ]))
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/ai_providers.json")) (renderCompact hydratedWithDisabled)
    let accountMarker := "admin-proxy-account-marker-1"
    let modelMarker := "admin-proxy-model-marker-v1"
    let discoveryMarker := "admin-discovery-connection-marker"
    let nowIsoReal := formatEpochIso8601Utc nowReal
    sql store.missionsDb
      "INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_cents,provider,account_id,api_key_id,api_key_name,mission_id,caller_kind,purpose,reasoning_tokens,account_bound) VALUES(?1,?2,100,50,0,0,12,'anthropic',?3,'','','admin-mission','mission','turn',0,1);"
      #[nowIsoReal, modelMarker, accountMarker]
    sql store.missionsDb
      "INSERT INTO proxy_outcomes(timestamp,chain_id,provider,account_id,model,status,http_status,retries,ttft_ms,total_ms,fallback_depth,stream,superseded) VALUES(?1,'builtin/smart','anthropic',?2,?3,'error',502,1,0,120,0,0,0);"
      #[nowIsoReal, accountMarker, modelMarker]
    let discoveryJson : JVal := .obj #[
      ("schema_version", .nat 1),
      ("connections", .arr #[
        .obj #[
          ("provider_id", .str "anthropic"),
          ("label", .str discoveryMarker),
          ("access_profile", .str discoveryMarker),
          ("account_email", .str provEmailMarker),
          ("organization", .str provOrgMarker),
          ("diagnostic", .str discoveryMarker),
          ("status", .str "discovered"),
          ("source", .str "discovery"),
          ("checked_at", .str nowIsoReal),
          ("last_success", .obj #[
            ("observed_at", .str nowIsoReal),
            ("completeness", .str "complete"),
            ("models", .arr #[.obj #[("id", .str "claude-sonnet-4-5")]])
          ])
        ]
      ])
    ]
    IO.FS.writeFile (System.FilePath.mk (store.rootDir ++ "/model-discovery.json")) (renderCompact discoveryJson)
    let siblingRoutes : Array (String × String) := #[
      ("GET /api/providers/catalog", "/api/providers/catalog"),
      ("GET /api/providers/discovery", "/api/providers/discovery"),
      ("GET /api/ai/usage/summary", "/api/ai/usage/summary"),
      ("GET /api/ai/proxy/health", "/api/ai/proxy/health"),
      ("GET /api/ai/proxy/timing", "/api/ai/proxy/timing"),
      ("GET /api/model-routing/health", "/api/model-routing/health")
    ]
    let siblingMarkers : Array String := #[
      provNameMarker,
      "admin-provider-name-marker-beta",
      disabledProvMarker,
      provEmailMarker,
      provOrgMarker,
      "admin-mission",
      accountMarker,
      modelMarker,
      discoveryMarker
    ]
    let stripGeneratedAt (jv : JVal) : JVal :=
      match jv with
      | .obj kvs => .obj (kvs.filter (fun (k, _) => k != "generated_at" && k != "window_start" && k != "since"))
      | other => other
    let mut adminSiblingDocs : Array JVal := #[]
    for (routeName, target) in siblingRoutes do
      let (aStatus, aDoc) ← send "GET" target admin (.obj #[]) stWithProviders
      let some (lStatus, _, lBytes) ← dispatchProviderAndAiRoute pHub store path 3000 none
          stWithProviders.proxyCooldownsRef "GET" target target ByteArray.empty "" false true stWithProviders.healthTracker?
        | throw (IO.userError s!"legacy unscoped dispatch missing on {routeName}")
      let .ok lDoc := OrbBin.Json.parseBytes lBytes
        | throw (IO.userError s!"legacy unscoped JSON parse failed on {routeName}")
      check (aStatus == 200 && lStatus == 200) s!"admin and legacy unscoped status 200 on {routeName}"
      check (renderCompact (stripGeneratedAt aDoc) == renderCompact (stripGeneratedAt lDoc))
        s!"admin and legacy unscoped receive identical response on {routeName}"
      adminSiblingDocs := adminSiblingDocs.push aDoc
    let adminSiblingCombined := renderCompact (.arr adminSiblingDocs)
    for marker in #[provNameMarker, "admin-provider-name-marker-beta", disabledProvMarker, "admin-mission", accountMarker, modelMarker, discoveryMarker] do
      check ((adminSiblingCombined.splitOn marker).length > 1) s!"admin sees sibling route marker {marker}"
    let mut siblingLeaks : Array String := #[]
    for (routeName, target) in siblingRoutes do
      let (mStatus, mDoc) ← send "GET" target member (.obj #[]) stWithProviders
      check (mStatus == 200) s!"member status 200 on {routeName}"
      let raw := renderCompact mDoc
      let mut leakedOnRoute : Array String := #[]
      for marker in siblingMarkers do
        if (raw.splitOn marker).length > 1 then
          leakedOnRoute := leakedOnRoute.push marker
      if !leakedOnRoute.isEmpty then
        let joinedMarkers := String.intercalate ", " leakedOnRoute.toList
        siblingLeaks := siblingLeaks.push s!"{routeName} ({mStatus}) -> [{joinedMarkers}]"
    let joinedSiblingLeaks := String.intercalate "; " siblingLeaks.toList
    check siblingLeaks.isEmpty s!"member sibling provider/ai routes leaked owner identity: {joinedSiblingLeaks}"
    -- Host-level views: members get their own missions only and no host paths.
    sql store.missionsDb
      "INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_cents,provider,account_id,api_key_id,api_key_name,mission_id,caller_kind,purpose,reasoning_tokens,account_bound) VALUES(?1,'claude-sonnet-4-5',80,40,0,0,5,'anthropic','member-acct','','','member-mission','mission','turn',0,1);"
      #[nowIsoReal]
    let (ovAdminSt, ovAdminDoc) ← send "GET" "/api/resources/overview" admin (.obj #[]) stWithProviders
    let (ovSt, ovDoc) ← send "GET" "/api/resources/overview" member (.obj #[]) stWithProviders
    let ovComp := ovDoc.fieldOrNull "compute"
    let ovMissions := (ovDoc.fieldArr? "missions").getD #[]
    check (ovSt == 200 && ((renderCompact ovDoc).splitOn "admin-mission").length == 1 &&
        ((ovDoc.field? "compute").bind (·.fieldArr? "sources")) == some #[] &&
        ((ovDoc.field? "inference").bind (·.fieldArr? "pools")) == some #[] &&
        ovDoc.fieldArr? "links" == some #[] &&
        ovComp.field? "total_vcpu" == some (.num "0.000") &&
        ovComp.field? "active_vcpu" == some (.num "0.000") &&
        ovMissions.any (fun m => m.fieldStr? "id" == some "member-mission") &&
        ovAdminSt == 200 &&
        ((renderCompact ovAdminDoc).splitOn "admin-mission").length > 1 &&
        !((ovAdminDoc.fieldArr? "links").getD #[]).isEmpty)
      s!"member resources overview hides other users' missions, fleet sources and inference pools (member={renderCompact ovDoc})"
    let (lsSt, lsDoc) ← send "GET" "/api/library/status" member (.obj #[]) stWithProviders
    check (lsSt != 200 || (lsDoc.fieldStr? "path" == some "" && lsDoc.fieldStr? "remote" == some (path ++ "/fixture-library")))
      "member library status hides host path and returns only own remote"
    let (siSt, siDoc) ← send "GET" "/api/system/info" member (.obj #[]) stWithProviders
    check (siSt == 200 && ((siDoc.fieldArr? "components").getD #[]).all (fun c => (c.field? "path").getD .null == .null))
      "member system info hides binary paths"
    let (skSt, skDoc) ← send "GET" "/api/library/skill" member (.obj #[]) stWithProviders
    check (skSt == 200 && ((renderCompact skDoc).splitOn "owner-only-skill").length == 1 &&
      ((renderCompact skDoc).splitOn "member-only-skill").length > 1) "member Library skill list is own"
    check ((← send "GET" "/api/library/skill/paloma-infra" member (.obj #[]) stWithProviders).1 == 404)
      "member cannot read a Library skill body"
    let (swSt, swDoc) ← send "GET" "/api/software" member (.obj #[]) stWithProviders
    check (swSt == 200 && ((swDoc.fieldArr? "components").getD #[]).all (fun c => (c.field? "binary_path").getD .null == .null))
      "member software inventory hides binary paths"
    check ((← send "POST" "/api/software/updates" member (.obj #[]) stWithProviders).1 == 403)
      "member cannot start software updates"
    let (_, mCatDoc) ← send "GET" "/api/providers/catalog" member (.obj #[]) stWithProviders
    let mCatProvs := (mCatDoc.fieldArr? "providers").getD #[]
    check (mCatProvs.size == 2 &&
      (mCatProvs[0]?.bind (·.fieldStr? "name")) == some "Anthropic 1" &&
      (mCatProvs[1]?.bind (·.fieldStr? "name")) == some "Anthropic 2")
      "member /api/providers/catalog keeps enabled configured rows with memberProviderDisplayName"
    let (_, mDiscDoc) ← send "GET" "/api/providers/discovery" member (.obj #[]) stWithProviders
    let mConns := (mDiscDoc.fieldArr? "connections").getD #[]
    check (mConns.size == 1 &&
      (mConns[0]?.bind (·.fieldStr? "provider_id")) == some "anthropic" &&
      (mConns[0]?.bind (·.fieldStr? "status")) == some "discovered" &&
      (mConns[0]?.bind (·.fieldStr? "access_profile")) == some "Anthropic 1")
      "member /api/providers/discovery keeps model-evidence connection with projected display name"
    let (_, mHealthDoc) ← send "GET" "/api/model-routing/health" member (.obj #[]) stWithProviders
    let mHealthRows := mHealthDoc.asArr?.getD #[]
    check (mHealthRows.size == 2 &&
      (mHealthRows[0]?.bind (·.fieldStr? "account_id")) == some "prov-anth-1" &&
      (mHealthRows[1]?.bind (·.fieldStr? "account_id")) == some "prov-anth-2" &&
      mHealthRows.all (fun r =>
        r.fieldStr? "provider_id" == some "anthropic" &&
        r.fieldUInt64? "cooldown_remaining_secs" == r.fieldUInt64? "cooldown_secs_remaining" &&
        r.fieldBool? "is_healthy" == some true &&
        r.fieldBool? "is_degraded" == some false))
      "member /api/model-routing/health keeps only enabled configured providers"
    let (_, mProxyHealthDoc) ← send "GET" "/api/ai/proxy/health" member (.obj #[]) stWithProviders
    let mProxyTot := mProxyHealthDoc.fieldOrNull "totals"
    check (mProxyHealthDoc.field? "since" == mProxyHealthDoc.field? "window_start" &&
      mProxyHealthDoc.fieldArr? "groups" == some #[] &&
      mProxyHealthDoc.fieldArr? "chains" == some #[] &&
      mProxyTot.fieldNat? "requests" == some 0 &&
      mProxyTot.fieldNat? "ok" == some 0 &&
      mProxyTot.fieldNat? "retried" == some 0 &&
      (mProxyTot.field? "fell_back").isNone &&
      mProxyTot.field? "errors" == some (.obj #[]))
      "member /api/ai/proxy/health returns empty groups, chains, and zeroed totals"
    let (_, mUsageDoc) ← send "GET" "/api/ai/usage/summary" member (.obj #[]) stWithProviders
    let mUsageTot := mUsageDoc.fieldOrNull "totals"
    check (mUsageDoc.field? "since" == mUsageDoc.field? "window_start" &&
      mUsageTot.fieldNat? "requests" == some 0 &&
      mUsageTot.fieldNat? "events" == some 0 &&
      (mUsageTot.field? "cost_cents").isNone &&
      (mUsageTot.field? "unknown_cost_requests").isNone &&
      mUsageDoc.fieldArr? "by_route" == some #[] &&
      mUsageDoc.fieldArr? "by_root_mission" == some #[] &&
      mUsageDoc.fieldArr? "by_hour" == some #[] &&
      mUsageDoc.fieldArr? "by_day" == some #[] &&
      mUsageDoc.fieldArr? "by_mission" == some #[])
      "member /api/ai/usage/summary returns zeroed totals and empty breakdown arrays"
    -- Held-open SSE streams (`GET /api/control/stream` and `GET /api/control/missions/:id/stream`)
    -- over real loopback TCP sockets before disabling/deleting the member principal.
    sql store.missionsDb "DELETE FROM mission_shares WHERE mission_id='admin-mission' AND user_id='member';"
    let adminLiveTok := mintSessionTokenV2 stWithProviders.cfg.jwtSecret "admin" "admin" 1 (nowReal + 3600)
    let memberLiveTok := mintSessionTokenV2 stWithProviders.cfg.jwtSecret "member" "member" 1 (nowReal + 3600)
    let sseHub ← newBroadcastHub
    let stSse : CoreAppState := { stWithProviders with broadcastHub? := some sseHub, sseKeepAliveMs? := some 60 }
    let .ok (sseListenFd, ssePort) ← tcpListen "127.0.0.1" 0 32
      | throw (IO.userError "SSE loopback tcpListen failed")
    let sseAcceptDone ← IO.mkRef false
    let sseServerTask ← IO.asTask (prio := .dedicated) do
      while !(← sseAcceptDone.get) do
        if let .ok sfd ← tcpAcceptPoll sseListenFd 100 then
          discard <| IO.asTask (prio := .dedicated) (handleClientConn stSse sfd false)
      discard <| closeFd sseListenFd
    let openSseSocket (target : String) (bearer? : Option String) : IO Fd := do
      let .ok fd ← tcpConnect "127.0.0.1" ssePort
        | throw (IO.userError s!"SSE tcpConnect failed for {target}")
      let authHdr := match bearer? with
        | some b => s!"Authorization: Bearer {b}\r\n"
        | none => ""
      let reqWire :=
        s!"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n{authHdr}\r\n".toUTF8
      let .ok _ ← writeAll fd reqWire false
        | do discard <| closeFd fd; throw (IO.userError s!"SSE writeAll failed for {target}")
      return fd
    let drainSseUntil (fd : Fd) (timeoutMs : Nat) (pred : String → Bool) : IO (String × Bool) := do
      let startMs ← IO.monoMsNow
      let mut acc := ByteArray.empty
      let mut hitEof := false
      while (← IO.monoMsNow) - startMs < timeoutMs do
        let decoded := String.fromUTF8? acc |>.getD ""
        if pred decoded then
          return (decoded, hitEof)
        let elapsed := (← IO.monoMsNow) - startMs
        let rem := if timeoutMs > elapsed then timeoutMs - elapsed else 1
        let stepMs : UInt32 := (min 50 (max 1 rem)).toUInt32
        match ← pollReadable fd stepMs with
        | .ok () =>
          let ch ← readStreamChunk fd 16384
          if ch.isEmpty then
            hitEof := true
            break
          acc := acc ++ ch
        | .error _ => pure ()
      return (String.fromUTF8? acc |>.getD "", hitEof)
    try
      -- (f) Auth enforcement on both SSE routes before any stream opens (`401` unauthenticated, `404` foreign mission).
      let unauthFd1 ← openSseSocket "/api/control/stream" none
      let (unauthWire1, _) ← drainSseUntil unauthFd1 800 (fun s => (s.splitOn "\r\n\r\n").length > 1)
      discard <| closeFd unauthFd1
      check ((unauthWire1.splitOn "HTTP/1.1 401").length > 1)
        s!"SSE (f) unauthenticated /api/control/stream must return 401, got: {unauthWire1}"
      let unauthFd2 ← openSseSocket "/api/control/missions/member-mission/stream" none
      let (unauthWire2, _) ← drainSseUntil unauthFd2 800 (fun s => (s.splitOn "\r\n\r\n").length > 1)
      discard <| closeFd unauthFd2
      check ((unauthWire2.splitOn "HTTP/1.1 401").length > 1)
        s!"SSE (f) unauthenticated /api/control/missions/:id/stream must return 401, got: {unauthWire2}"
      let foreignFd ← openSseSocket "/api/control/missions/admin-mission/stream" (some memberLiveTok)
      let (foreignWire, _) ← drainSseUntil foreignFd 800 (fun s => (s.splitOn "\r\n\r\n").length > 1)
      discard <| closeFd foreignFd
      check ((foreignWire.splitOn "HTTP/1.1 404").length > 1)
        s!"SSE (f) member opening foreign /api/control/missions/admin-mission/stream must return 404, got: {foreignWire}"

      -- (a), (b) & (c) Live control stream stays open past initial `missions_snapshot`, scopes snapshot + live events
      -- strictly by mission ownership/share (admin does NOT receive unshared member-mission events), delivers
      -- member-mission events to admin within 2.5 s after sharing, and delivers missionId=none frames to admin only.
      let adminStreamFd ← openSseSocket "/api/control/stream" (some adminLiveTok)
      let memberStreamFd ← openSseSocket "/api/control/stream" (some memberLiveTok)
      let (adminInitWire, adminInitEof) ← drainSseUntil adminStreamFd 1000
        (fun s => (s.splitOn "event: missions_snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      let (memberInitWire, memberInitEof) ← drainSseUntil memberStreamFd 1000
        (fun s => (s.splitOn "event: missions_snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      check (!adminInitEof && !memberInitEof &&
          (adminInitWire.splitOn "HTTP/1.1 200 OK").length > 1 &&
          (adminInitWire.splitOn "Transfer-Encoding: chunked").length > 1 &&
          (adminInitWire.splitOn "event: missions_snapshot").length > 1 &&
          (adminInitWire.splitOn "admin-mission").length > 1 &&
          (adminInitWire.splitOn "member-mission").length == 1 &&
          (memberInitWire.splitOn "event: missions_snapshot").length > 1 &&
          (memberInitWire.splitOn "member-mission").length > 1 &&
          (memberInitWire.splitOn "admin-mission").length == 1)
        s!"SSE (a)/(b) initial missions_snapshot chunked stream or tenant scoping failed (adminEof={adminInitEof}, memberEof={memberInitEof})"
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"member-visible-sse-live\"}"
        (some "member-mission")
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"admin-only-sse-live\"}"
        (some "admin-mission")
      let (adminLiveWire, adminLiveEof) ← drainSseUntil adminStreamFd 1000
        (fun s => (s.splitOn "admin-only-sse-live").length > 1)
      let (memberLiveWire, memberLiveEof) ← drainSseUntil memberStreamFd 400
        (fun s => (s.splitOn "member-visible-sse-live").length > 1)
      check (!adminLiveEof && !memberLiveEof &&
          (adminLiveWire.splitOn "admin-only-sse-live").length > 1 &&
          (adminLiveWire.splitOn "member-visible-sse-live").length == 1 &&
          (memberLiveWire.splitOn "member-visible-sse-live").length > 1 &&
          (memberLiveWire.splitOn "admin-only-sse-live").length == 1)
        s!"SSE (a) live event delivery or strict non-owner admin isolation failed (adminLive={adminLiveWire}, memberLive={memberLiveWire})"
      sql store.missionsDb "INSERT INTO mission_shares(mission_id,user_id,granted_by) VALUES('member-mission','admin','member');"
      let mut adminShareWire := ""
      let mut adminShareEof := false
      let shareStartMs ← IO.monoMsNow
      while (← IO.monoMsNow) - shareStartMs < 2500 &&
            (adminShareWire.splitOn "member-shared-to-admin-sse").length == 1 &&
            !adminShareEof do
        publishControlEvent (some sseHub) "text_delta"
          "{\"content\":\"member-shared-to-admin-sse\"}"
          (some "member-mission")
        let (piece, eof) ← drainSseUntil adminStreamFd 250
          (fun s => (s.splitOn "member-shared-to-admin-sse").length > 1)
        adminShareWire := adminShareWire ++ piece
        adminShareEof := eof
      sql store.missionsDb "DELETE FROM mission_shares WHERE mission_id='member-mission' AND user_id='admin';"
      check (!adminShareEof && (adminShareWire.splitOn "member-shared-to-admin-sse").length > 1)
        s!"SSE (b) admin did not receive shared member-mission frame within 2.5s: {adminShareWire}"
      let (_, _) ← drainSseUntil memberStreamFd 200 (fun _ => false)
      publishControlEvent (some sseHub) "system_notice"
        "{\"message\":\"missionless-admin-only-notice\"}"
        none
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"member-post-notice-fence\"}"
        (some "member-mission")
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"admin-post-notice-fence\"}"
        (some "admin-mission")
      let (adminNoticeWire, adminNoticeEof) ← drainSseUntil adminStreamFd 1000
        (fun s => (s.splitOn "missionless-admin-only-notice").length > 1 && (s.splitOn "admin-post-notice-fence").length > 1)
      let (memberNoticeWire, memberNoticeEof) ← drainSseUntil memberStreamFd 1000
        (fun s => (s.splitOn "member-post-notice-fence").length > 1)
      check (!adminNoticeEof && !memberNoticeEof &&
          (adminNoticeWire.splitOn "missionless-admin-only-notice").length > 1 &&
          (memberNoticeWire.splitOn "member-post-notice-fence").length > 1 &&
          (memberNoticeWire.splitOn "missionless-admin-only-notice").length == 1)
        s!"SSE (c) missionId=none frame visibility failed (adminNotice={adminNoticeWire}, memberNotice={memberNoticeWire})"
      let memberMissionStreamFd ← openSseSocket "/api/control/missions/member-mission/stream" (some memberLiveTok)
      let (_, memberMissionInitEof) ← drainSseUntil memberMissionStreamFd 1000
        (fun s => (s.splitOn "event: snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      check (!memberMissionInitEof) "SSE (a)/(b) member mission stream closed prematurely"
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"admin-only-mission-delta\"}"
        (some "admin-mission")
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"member-mission-delta\"}"
        (some "member-mission")
      let (memberMissionLiveWire, memberMissionLiveEof) ← drainSseUntil memberMissionStreamFd 400
        (fun s => (s.splitOn "member-mission-delta").length > 1)
      discard <| closeFd memberMissionStreamFd
      check (!memberMissionLiveEof &&
          (memberMissionLiveWire.splitOn "member-mission-delta").length > 1 &&
          (memberMissionLiveWire.splitOn "admin-only-mission-delta").length == 1)
        s!"SSE (a)/(b) member mission stream payload-less text_delta failed: {memberMissionLiveWire}"

      -- (d) Keep-alive comment `: keep-alive\n\n` arrives on an idle open stream within the configured short interval.
      let (keepAliveWire, keepAliveEof) ← drainSseUntil memberStreamFd 600
        (fun s => (s.splitOn ": keep-alive\n\n").length > 1)
      check (!keepAliveEof && (keepAliveWire.splitOn ": keep-alive\n\n").length > 1)
        s!"SSE (d) expected ': keep-alive' frame on open stream, got eof={keepAliveEof} wire={keepAliveWire}"
      discard <| closeFd adminStreamFd
      discard <| closeFd memberStreamFd

      -- Token expiry: a stream opened with exp = now + 2 reaches EOF within 5 s, while a stream
      -- opened at the same time with exp = now + 3600 remains open.
      let nowForExp ← coreEpochSec
      let shortExpTok := mintSessionTokenV2 stWithProviders.cfg.jwtSecret "admin" "admin" 1 (nowForExp + 2)
      let longExpTok := mintSessionTokenV2 stWithProviders.cfg.jwtSecret "admin" "admin" 1 (nowForExp + 3600)
      let shortExpFd ← openSseSocket "/api/control/stream" (some shortExpTok)
      let longExpFd ← openSseSocket "/api/control/stream" (some longExpTok)
      let (_, shortInitEof) ← drainSseUntil shortExpFd 1000
        (fun s => (s.splitOn "event: missions_snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      let (_, longInitEof) ← drainSseUntil longExpFd 1000
        (fun s => (s.splitOn "event: missions_snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      check (!shortInitEof && !longInitEof) "SSE token expiry streams closed prematurely on init"
      let (_, shortExpEof) ← drainSseUntil shortExpFd 5000 (fun _ => false)
      publishControlEvent (some sseHub) "text_delta"
        "{\"content\":\"long-token-still-alive\"}"
        (some "admin-mission")
      let (longAliveWire, longExpEof) ← drainSseUntil longExpFd 500
        (fun s => (s.splitOn "long-token-still-alive").length > 1)
      discard <| closeFd shortExpFd
      discard <| closeFd longExpFd
      check (shortExpEof && !longExpEof && (longAliveWire.splitOn "long-token-still-alive").length > 1)
        s!"SSE token expiry check failed (shortExpEof={shortExpEof}, longExpEof={longExpEof}, longWire={longAliveWire})"

      -- (c) Mission-scoped stream (`/api/control/missions/:id/stream` and `/api/control/stream?mission=:id`)
      -- delivers only that mission's events and drops other visible missions' events.
      let _ ← appendMissionEvent store "admin-mission" "user_message"
        "{\"id\":\"u-hist-1\",\"content\":\"hist-seq-1\"}" "2026-11-13T10:01:00Z"
      let (seqHist2Res) ← appendMissionEvent store "admin-mission" "assistant_message"
        "{\"id\":\"a-hist-2\",\"content\":\"hist-seq-2\"}" "2026-11-13T10:01:01Z"
      let seqHist1 : UInt64 := match seqHist2Res with | .ok s => if s > 1 then s - 1 else 1 | .error _ => 1
      let missionStreamFd ← openSseSocket s!"/api/control/missions/admin-mission/stream?since_seq={seqHist1}" (some adminLiveTok)
      let (mInitWire, mInitEof) ← drainSseUntil missionStreamFd 1000
        (fun s => (s.splitOn "hist-seq-2").length > 1)
      check (!mInitEof &&
          (mInitWire.splitOn "hist-seq-2").length > 1 &&
          (mInitWire.splitOn "hist-seq-1").length == 1)
        s!"SSE (c) mission stream since_seq replay mismatch: {mInitWire}"
      publishControlEvent (some sseHub) "mission_status_changed"
        "{\"status\":\"awaiting_user\",\"marker\":\"other-mission-noise\"}"
        (some "member-mission")
      publishControlEvent (some sseHub) "mission_status_changed"
        "{\"status\":\"awaiting_user\",\"marker\":\"target-mission-signal\"}"
        (some "admin-mission")
      let (mFilterWire, mFilterEof) ← drainSseUntil missionStreamFd 1000
        (fun s => (s.splitOn "target-mission-signal").length > 1)
      check (!mFilterEof &&
          (mFilterWire.splitOn "target-mission-signal").length > 1 &&
          (mFilterWire.splitOn "other-mission-noise").length == 1)
        s!"SSE (c) mission stream failed to filter out other mission's event: {mFilterWire}"

      -- (e) Disconnect cleanup and `stream_lagged` overflow notice:
      -- Closing the client socket is detected by the failed write within two keep-alive intervals
      -- and unregisters its subscriber from `BroadcastHub`; overflowing a live subscriber queue
      -- (> 256 frames) emits `event: stream_lagged` with `dropped > 0`.
      let subsBeforeClose ← sseHub.mu.atomically do return (← get).2.size
      check (subsBeforeClose ≥ 1) s!"SSE (e) expected active subscriber before close, got {subsBeforeClose}"
      discard <| closeFd missionStreamFd
      let mut subsAfterClose := subsBeforeClose
      for _ in [0:20] do
        IO.sleep 20
        subsAfterClose ← sseHub.mu.atomically do return (← get).2.size
        if subsAfterClose == 0 then break
      check (subsAfterClose == 0)
        s!"SSE (e) closed client socket did not unregister SSE subscriber within keep-alive bound (remaining={subsAfterClose})"

      -- (e)(i) Hub-level overflow check (deterministic, no stream loop):
      let directSub ← registerSseSubscriberFull sseHub (some "member-mission")
      for idx in [0:270] do
        publishControlEvent (some sseHub) "mission_status_changed"
          s!"\{\"status\":\"running\",\"seq_idx\":{idx}}"
          (some "member-mission")
      let directDropped ← directSub.droppedRef.get
      let directEvents ← directSub.eventsRef.get
      unregisterSseSubscriber sseHub directSub.id
      let oldestFrame := match directEvents[0]? with | some ev => ev.frame | none => ""
      check (directDropped == 14 &&
          directEvents.size == 256 &&
          (oldestFrame.splitOn "\"seq_idx\":14").length > 1)
        s!"SSE (e)(i) hub-level 256-frame overflow mismatch (dropped={directDropped}, size={directEvents.size}, oldest={oldestFrame})"

      -- (e)(ii) Socket-level `stream_lagged` check (repeat 270-frame burst up to 5 times):
      let lagFd ← openSseSocket "/api/control/missions/member-mission/stream" (some memberLiveTok)
      let (_, lagInitEof) ← drainSseUntil lagFd 1000
        (fun s => (s.splitOn "event: snapshot").length > 1 && (s.splitOn "\n\n").length > 1)
      check (!lagInitEof) "SSE (e)(ii) lag test stream closed prematurely"
      let mut lagWire := ""
      for _ in [0:5] do
        if (lagWire.splitOn "event: stream_lagged").length == 1 ||
           (lagWire.splitOn "\"dropped\":").length == 1 then
          for idx in [0:270] do
            publishControlEvent (some sseHub) "mission_status_changed"
              s!"\{\"status\":\"running\",\"seq_idx\":{idx}}"
              (some "member-mission")
          let (piece, _) ← drainSseUntil lagFd 600
            (fun s => (s.splitOn "event: stream_lagged").length > 1 && (s.splitOn "\"dropped\":").length > 1)
          lagWire := lagWire ++ piece
      discard <| closeFd lagFd
      check ((lagWire.splitOn "event: stream_lagged").length > 1 &&
          (lagWire.splitOn "\"dropped\":").length > 1)
        s!"SSE (e)(ii) overflowing 256-frame subscriber queue did not emit stream_lagged: {lagWire}"
    finally
      sseAcceptDone.set true
      let _ := sseServerTask.get
    -- R12 named failing regression tests:
    -- 1. r12_legacy_token_unknown_subject_never_yields_session (SEC-02)
    let unknownLegacyJwt := issueHs256Jwt st.cfg.jwtSecret "unknown-subject" "ghost" now (now + 3600) "admin"
    let (unkJwtSt, _) ← send "GET" "/api/auth/me" unknownLegacyJwt
    check (unkJwtSt == 401)
      s!"r12_legacy_token_unknown_subject_never_yields_session (got {unkJwtSt})"
    -- 2. r12_database_rejected_password_never_yields_session (HTTP-01 / SEC-02)
    let rotatedHash ← hashPasswordPbkdf2 "rotated-db-password-999"
    sql store.missionsDb "UPDATE users SET password_hash=?1 WHERE id='member';" #[rotatedHash]
    let (rawBearerSt, _) ← send "GET" "/api/auth/me" "configured-member-password-123" (.obj #[]) configured
    let (staleLoginSt, _) ← send "POST" "/api/auth/login" ""
      (.obj #[("username", .str "member"), ("password", .str "configured-member-password-123")]) configured
    check (rawBearerSt == 401 && staleLoginSt == 401)
      s!"r12_database_rejected_password_never_yields_session (bearer={rawBearerSt}, login={staleLoginSt})"
    -- 3. r12_http01_sec03_nested_auth_password_hash_precedence_and_redaction (SEC-03 / HTTP-01)
    let rustSavedHash ← hashPasswordPbkdf2 "rust-saved-admin-pass-777"
    let r12Dir := root ++ "/r12-sec03-hydrate"
    IO.FS.createDirAll (System.FilePath.mk r12Dir)
    IO.FS.writeFile (System.FilePath.mk (r12Dir ++ "/settings.json"))
      s!"\{\"auth\":\{\"password_hash\":{jsonEscape rustSavedHash},\"password_changed_at\":\"2026-11-10T00:00:00Z\"}}"
    let .ok r12Store ← openCoreStore r12Dir | throw (IO.userError "r12 store")
    let .ok r12Mc ← openManagedComputeStore (r12Dir ++ "/managed_compute.db") | throw (IO.userError "r12 mc")
    try
      let .ok bootId ← bootstrapUsersAndBackfill r12Store #[("admin", "env-bootstrap-pass-111")] s!"{now}"
        | throw (IO.userError "r12 bootstrap")
      hydrateLegacyDataDir r12Dir r12Dir r12Store r12Mc bootId false
      let r12St : CoreAppState := {
        st with
        cfg := { st.cfg with workingDir := r12Dir, dashboardPassword := "env-bootstrap-pass-111", usersJson := "" }
        store := r12Store
        managedStore? := some r12Mc
        bootstrapAdminId := bootId
      }
      let (envLoginSt, _) ← send "POST" "/api/auth/login" ""
        (.obj #[("password", .str "env-bootstrap-pass-111")]) r12St
      let (savedLoginSt, savedLoginDoc) ← send "POST" "/api/auth/login" ""
        (.obj #[("password", .str "rust-saved-admin-pass-777")]) r12St
      let savedTok := (savedLoginDoc.fieldStr? "token").getD ""
      let (setSt, setDoc) ← send "GET" "/api/settings" savedTok (.obj #[]) r12St
      let setRaw := renderCompact setDoc
      check (envLoginSt == 401 && savedLoginSt == 200 && setSt == 200 &&
          (setRaw.splitOn "password_hash").length == 1 && (setRaw.splitOn rustSavedHash).length == 1)
        s!"r12_http01_sec03_nested_auth_password_hash_precedence_and_redaction (env={envLoginSt}, saved={savedLoginSt}, set={setSt})"
    finally
      closeManagedComputeStore r12Mc
      closeCoreStore r12Store
    -- 4. r12_valid_v2_session_credentials_resolve_principal
    let (v2AdmSt, v2AdmDoc) ← send "GET" "/api/auth/me" admin
    let (v2MemSt, v2MemDoc) ← send "GET" "/api/auth/me" member
    check (v2AdmSt == 200 && (v2AdmDoc.fieldOrNull "user").fieldStr? "id" == some "admin" &&
        v2MemSt == 200 && (v2MemDoc.fieldOrNull "user").fieldStr? "id" == some "member")
      s!"r12_valid_v2_session_credentials_resolve_principal (adm={v2AdmSt}, mem={v2MemSt})"
    -- 5. r12_mission_mcp_and_proxy_credentials_resolve_principal
    let mcpCapDoc ← call memberSession "get_capabilities"
    let .ok mptTok ← mintMissionProxyToken store "member-mission" "member" (now + 3600)
      | throw (IO.userError "r12 mintMissionProxyToken")
    let mptOk ← authenticateProxyRequest st #[("authorization", s!"Bearer {mptTok}")] now
    check (mcpCapDoc.fieldBool? "ok" == some true && mptOk)
      s!"r12_mission_mcp_and_proxy_credentials_resolve_principal (mcpOk={mcpCapDoc.fieldBool? "ok"}, mptOk={mptOk})"
    -- 6. r12_node_token_credentials_resolve_principal
    let r12Vm : ManagedMachine := {
      id := "mm-r12-node-1", sandboxName := "orb-managed-mm-r12-node-1", provider := "boat",
      size := "small", spentCents := 25, nodeBootEpoch := 1, deletableAtSec := 100
    }
    let .ok _ ← provisionManagedMachine mc { enabled := true, boatEnabled := true } r12Vm 50
      | throw (IO.userError "r12 provisionManagedMachine")
    let .ok () ← bindManagedProviderId mc r12Vm.id "boat-r12-1" 1
      | throw (IO.userError "r12 bindManagedProviderId")
    let .ok () ← putEnrollmentToken mc r12Vm.id "r12-enroll-tok-1"
      | throw (IO.userError "r12 putEnrollmentToken")
    let .ok (_, r12NodeTok) ← enrollManagedNode mc r12Vm.id "r12-enroll-tok-1" (some 1)
      | throw (IO.userError "r12 enrollManagedNode")
    let nodePollWire := s!"GET /api/managed-machines/relay/poll HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {r12NodeTok}\r\nx-orb-machine-id: {r12Vm.id}\r\nx-orb-boot-epoch: 1\r\n\r\n"
    let .ok nodePollReq := parseRequest nodePollWire.toUTF8 none | throw (IO.userError "r12 node poll req")
    let .ok nodePollResp ← dispatchCoreRequest st nodePollReq now | throw (IO.userError "r12 node poll dispatch")
    check (nodePollResp.status == 200)
      s!"r12_node_token_credentials_resolve_principal (got {nodePollResp.status})"
    -- Disabling/deleting an issuer must stop every previously minted session,
    -- including an external session with no mission id and a shared mission.
    for update in #["UPDATE users SET disabled=1 WHERE id='member';", "DELETE FROM users WHERE id='member';"] do
      sql store.missionsDb update
      for bearer in #[memberSession, externalToken, sharedToken] do
        let (status, doc) ← send "POST" "/api/mcp/call" bearer (.obj #[("name", .str "get_mission"),
          ("arguments", .obj #[("mission_id", .str "member-mission")])])
        check (status == 401 || status == 403 || (status == 200 && doc.fieldBool? "ok" == some false))
          "disabled or deleted issuer cannot use old MCP sessions"
  finally
    closeManagedComputeStore mc
    closeCoreStore store

end OrbCore.TenantIsolationTests
