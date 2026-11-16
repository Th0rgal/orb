/- Mission board persistence. Deliberately independent of Store so startup can import it. -/
import OrbBin.Sqlite
import OrbBin.Json
import LeanSys.Auth

namespace OrbCore.MissionBoard

open OrbBin.Sqlite OrbBin.Json

def schemaSql : String :=
  "CREATE TABLE IF NOT EXISTS mission_board (mission_id TEXT PRIMARY KEY, text TEXT NOT NULL, " ++
  "updated_at TEXT NOT NULL, updated_by_mission_id TEXT NOT NULL, text_sha256 TEXT NOT NULL DEFAULT '');" ++
  "CREATE INDEX IF NOT EXISTS idx_mission_board_updated ON mission_board(updated_at);" ++
  "CREATE TABLE IF NOT EXISTS mission_board_migrations (name TEXT PRIMARY KEY, completed_at TEXT NOT NULL, detail TEXT NOT NULL);" ++
  -- Cleanup runs inside the deleting statement's transaction, including legacy delete paths.
  "CREATE TRIGGER IF NOT EXISTS mission_board_delete AFTER DELETE ON missions BEGIN " ++
  "DELETE FROM mission_board WHERE mission_id=OLD.id; END;"

def initSchema (db : SqliteDb) : IO (Except String Unit) :=
  db.mu.atomically (sqliteExecRaw db.handle schemaSql)

def digest (text : String) : String :=
  LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes text.toUTF8)

private def query (db : SqliteDb) (sql : String) (args : Array String) : IO (Except String (Array (Array String))) :=
  db.mu.atomically do
    return ← sqliteQueryRowsRaw db.handle sql args

private def transaction {α : Type} (db : SqliteDb) (act : IO (Except String α)) : IO (Except String α) :=
  db.mu.atomically do
    if let .error e ← sqliteExecRaw db.handle "BEGIN IMMEDIATE;" then return .error e
    try
      match ← act with
      | .error e =>
        discard <| sqliteExecRaw db.handle "ROLLBACK;"
        return .error e
      | .ok value =>
        if let .error e ← sqliteExecRaw db.handle "COMMIT;" then
          discard <| sqliteExecRaw db.handle "ROLLBACK;"
          return .error e
        return .ok value
    catch e =>
      discard <| sqliteExecRaw db.handle "ROLLBACK;"
      throw e

private def migrationName := "project-board-v1"

/-- Copy before recording completion. The optional interruption is a fixture failpoint:
    the committed copies survive, while startup can safely retry INSERT OR IGNORE.
    Legacy data is never modified. Caller serializes startup against request serving. -/
def migrate (missions projects : SqliteDb) (now : String) (interruptBeforeMarker : Bool := false)
    : IO (Except String Unit) := do
  let .ok marker ← query missions "SELECT name FROM mission_board_migrations WHERE name=?1;" #[migrationName]
    | return .error "board_migration_marker_read_failed"
  if marker.size > 1 then return .ok ()
  let .ok legacy ← query projects
      ("SELECT b.slug,b.text,b.updated_at,COALESCE(p.controller_mission_id,'') " ++
       "FROM project_board b LEFT JOIN projects p ON p.slug=b.slug ORDER BY b.slug;") #[]
    | return .error "board_migration_source_read_failed"
  let copied ← transaction missions do
    let mut unclaimed : Array JVal := #[]
    for r in legacy.extract 1 legacy.size do
      let controller := r[3]?.getD ""
      let .ok target ← sqliteQueryRowsRaw missions.handle "SELECT id FROM missions WHERE id=?1;" #[controller]
        | return Except.error "board_migration_target_read_failed"
      if controller.isEmpty || target.size ≤ 1 then
        unclaimed := unclaimed.push (.str (r[0]?.getD ""))
      else
        let text := r[1]?.getD ""
        if let .error e ← sqliteQueryRowsRaw missions.handle
            ("INSERT OR IGNORE INTO mission_board(mission_id,text,updated_at,updated_by_mission_id,text_sha256) " ++
             "VALUES(?1,?2,?3,?1,?4);") #[controller, text, r[2]?.getD "", digest text] then
          return .error e
    return .ok unclaimed
  let unclaimed ← match copied with
    | .ok value => pure value
    | .error e => return .error e
  if interruptBeforeMarker then return .error "board_migration_interrupted_before_marker"
  match ← query missions
      "INSERT OR IGNORE INTO mission_board_migrations(name,completed_at,detail) VALUES(?1,?2,?3);"
      #[migrationName, now, renderCompact (.obj #[("unclaimed", .arr unclaimed)])] with
  | .error e => return .error e
  | .ok _ => return .ok ()

structure Reader where
  userId : String
  missionId : String := ""
  role : String := ""

/-- The sole board read decision. A mission session never inherits its owner's
    user-wide read authority. Every lineage hop must have the authenticated issuer's
    owner id; shares and foreign intermediaries confer no authority. -/
def authorizeRead (db : SqliteDb) (reader : Reader) (target : String) : IO (Except String Unit) := do
  let .ok rows ← query db "SELECT owner_user_id,project FROM missions WHERE id=?1;" #[target]
    | return .error "db_error"
  if rows.size ≤ 1 || rows[1]![0]?.getD "" != reader.userId then return .error "mission_not_found"
  if reader.missionId.isEmpty then return .ok ()
  let .ok caller ← query db "SELECT owner_user_id,project FROM missions WHERE id=?1;" #[reader.missionId]
    | return .error "db_error"
  if caller.size ≤ 1 || caller[1]![0]?.getD "" != reader.userId then return .error "mission_not_found"
  if reader.missionId == target then return .ok ()
  let project := caller[1]![1]?.getD ""
  if !project.isEmpty && project == rows[1]![1]?.getD "" &&
      (reader.role == "operator" || reader.role == "coordinator") then return .ok ()
  let .ok ancestors ← query db
      ("WITH RECURSIVE edges(child,parent) AS (" ++
       "SELECT id,parent_mission_id FROM missions WHERE owner_user_id=?3 " ++
       "UNION SELECT m.id,substr(j.value,12) FROM missions m,json_each(m.tags) j " ++
       "WHERE m.owner_user_id=?3 AND j.type='text' AND substr(j.value,1,11)='btw-parent:' " ++
       "UNION SELECT m.id,substr(j.value,9) FROM missions m,json_each(m.tags) j " ++
       "WHERE m.owner_user_id=?3 AND j.type='text' AND substr(j.value,1,8)='fork-of:'), " ++
       "ancestors(id) AS (SELECT id FROM missions WHERE id=?1 AND owner_user_id=?3 " ++
       "UNION SELECT m.id FROM ancestors a JOIN edges e ON e.child=a.id JOIN missions m ON m.id=e.parent " ++
       "WHERE m.owner_user_id=?3) SELECT id FROM ancestors WHERE id=?2;")
      #[reader.missionId, target, reader.userId]
    | return .error "db_error"
  return if ancestors.size > 1 then .ok () else .error "forbidden"

def read (db : SqliteDb) (reader : Reader) (target : String) : IO (Except String JVal) := do
  if let .error e ← authorizeRead db reader target then return .error e
  let .ok rows ← query db "SELECT text,updated_at,updated_by_mission_id,text_sha256 FROM mission_board WHERE mission_id=?1;" #[target]
    | return .error "db_error"
  if rows.size ≤ 1 then return .ok (.obj #[("mission_id", .str target), ("text", .str ""),
    ("updated_at", .null), ("updated_by_mission_id", .null), ("text_sha256", .str (digest ""))])
  let r := rows[1]!
  return .ok (.obj #[("mission_id", .str target), ("text", .str (r[0]?.getD "")),
    ("updated_at", .str (r[1]?.getD "")), ("updated_by_mission_id", .str (r[2]?.getD "")),
    ("text_sha256", .str (r[3]?.getD ""))])

/-- REST currently has only user principals, so there is intentionally no write path. -/
def refuseUserWrite (db : SqliteDb) (user target : String) : IO String := do
  match ← authorizeRead db { userId := user } target with
  | .error e => return e
  | .ok () => return "not_mission_writer"

/-- A board and its settled MCP receipt share missions.db and one IMMEDIATE transaction.
    A missing fence differs from a present empty fence. The caller supplies a unique
    receipt id and authenticated scope; no board contents go to diagnostic output. -/
def write (db : SqliteDb) (reader : Reader) (target text now : String)
    (base : Option String) (actionId scope retryKey tool : String) : IO (Except String JVal) := do
  -- Tenant denial precedes writer and payload validation, including idempotent replay.
  let .ok owners ← query db "SELECT owner_user_id FROM missions WHERE id=?1;" #[target]
    | return .error "db_error"
  if owners.size ≤ 1 || owners[1]![0]?.getD "" != reader.userId then return .error "mission_not_found"
  if reader.missionId.isEmpty || reader.missionId != target then return .error "not_mission_writer"
  if text.utf8ByteSize > 16384 then return .error "board_too_large"
  transaction db do
    let q := sqliteQueryRowsRaw db.handle
    let .ok live ← q "SELECT owner_user_id FROM missions WHERE id=?1;" #[target]
      | return .error "db_error"
    if live.size ≤ 1 || live[1]![0]?.getD "" != reader.userId then return .error "mission_not_found"
    if !retryKey.isEmpty then
      let .ok replay ← q "SELECT result FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2 AND state='succeeded';" #[scope, retryKey]
        | return .error "db_error"
      if replay.size > 1 then
        return OrbBin.Json.parse (replay[1]![0]?.getD "")
    let .ok rows ← q "SELECT text,updated_at,updated_by_mission_id,text_sha256 FROM mission_board WHERE mission_id=?1;" #[target]
      | return .error "db_error"
    let previous := rows[1]?.getD #[]
    let timestamp := previous[1]?.getD ""
    if let some expected := base then
      if expected != timestamp then return .error "board_conflict"
    let identical := rows.size > 1 && previous[0]?.getD "" == text
    let result := JVal.obj #[("mission_id", .str target), ("text", .str text),
      ("updated_at", .str (if identical then timestamp else now)),
      ("updated_by_mission_id", .str (if identical then previous[2]?.getD "" else target)),
      ("text_sha256", .str (digest text))]
    if !identical then
      if let .error e ← q
          ("INSERT INTO mission_board(mission_id,text,updated_at,updated_by_mission_id,text_sha256) VALUES(?1,?2,?3,?1,?4) " ++
           "ON CONFLICT(mission_id) DO UPDATE SET text=excluded.text,updated_at=excluded.updated_at," ++
           "updated_by_mission_id=excluded.updated_by_mission_id,text_sha256=excluded.text_sha256;")
          #[target, text, now, digest text] then return .error e
    if let .error e ← q
        ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,tool,arguments,state,result,created_at,updated_at) " ++
         "VALUES(?1,?2,?3,?4,?5,'{}','succeeded',?6,?7,?7);")
        #[actionId, target, scope, if retryKey.isEmpty then "auto:" ++ actionId else retryKey,
          tool, renderCompact result, now] then return .error e
    return .ok result

def list (db : SqliteDb) (reader : Reader) (project : String) (all : Bool := false) : IO (Except String JVal) := do
  let .ok rows ← query db
      ("SELECT m.id,m.title,m.status,COALESCE(m.parent_mission_id,''),b.updated_at,length(CAST(b.text AS BLOB)),b.text_sha256 " ++
       "FROM missions m JOIN mission_board b ON b.mission_id=m.id WHERE m.project=?1 AND m.status<>'deleted' " ++
       "AND (?2='1' OR lower(m.status) NOT IN ('acknowledged','archived')) ORDER BY b.updated_at DESC,m.id ASC;")
      #[project, if all then "1" else "0"] | return .error "db_error"
  let mut boards := #[]
  for row in rows.extract 1 rows.size do
    let mid := row[0]?.getD ""
    match ← authorizeRead db reader mid with
    | .error "db_error" => return .error "db_error"
    | .error _ => pure ()
    | .ok () =>
      let parent := row[3]?.getD ""
      boards := boards.push (.obj #[("mission_id", .str mid), ("title", .str (row[1]?.getD "")),
        ("status", .str (row[2]?.getD "")), ("parent_mission_id", if parent.isEmpty then .null else .str parent),
        ("updated_at", .str (row[4]?.getD "")), ("bytes", .nat ((row[5]?.getD "0").toNat?.getD 0)),
        ("text_sha256", .str (row[6]?.getD ""))])
  return .ok (.obj #[("project", .str project), ("boards", .arr boards)])

private def jsonError (status : Nat) (code : String) : Nat × String × ByteArray :=
  (status, "application/json", renderCompact (.obj #[("error", .str code)]) |>.toUTF8)

/-- REST surface kept independent of Control. User principals may read; PUT is
    intentionally refused until Core has a mission-bound REST credential. -/
def dispatchRest (missions _projects : SqliteDb) (method target : String) (body : ByteArray)
    (reader : Reader) (project : String := "") (all : Bool := false) : IO (Option (Nat × String × ByteArray)) := do
  let segs := (target.splitOn "/").filter (!·.isEmpty)
  if segs.length == 5 && segs[0]? == some "api" && segs[1]? == some "control" &&
      segs[2]? == some "missions" && segs[4]? == some "board" then
    let mid := segs[3]!
    if method == "GET" then
      match ← read missions reader mid with
      | .ok result => return some (200, "application/json", renderCompact result |>.toUTF8)
      | .error "mission_not_found" => return some (jsonError 404 "mission_not_found")
      | .error "forbidden" => return some (jsonError 403 "forbidden")
      | .error _ => return some (jsonError 500 "db_error")
    if method == "PUT" then
      let _ := body
      match ← authorizeRead missions { reader with missionId := "" } mid with
      | .error "mission_not_found" => return some (jsonError 404 "mission_not_found")
      | .error _ => return some (jsonError 403 "not_mission_writer")
      | .ok () => return some (jsonError 403 "not_mission_writer")
  if segs.length == 4 && segs[0]? == some "api" && segs[1]? == some "projects" &&
      segs[3]? == some "boards" && method == "GET" then
    let requested := segs[2]!
    if !project.isEmpty && requested != project then return some (jsonError 404 "project_not_found")
    match ← list missions reader requested all with
    | .ok result => return some (200, "application/json", renderCompact result |>.toUTF8)
    | .error _ => return some (jsonError 404 "project_not_found")
  return none

end OrbCore.MissionBoard
