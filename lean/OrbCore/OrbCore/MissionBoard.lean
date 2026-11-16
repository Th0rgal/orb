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

end OrbCore.MissionBoard
