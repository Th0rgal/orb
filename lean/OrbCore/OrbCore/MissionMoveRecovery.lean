import OrbCore.Store

namespace OrbCore.MissionMoveRecovery

open OrbCore.Store OrbBin.Sqlite

def ensureSchema (db : SqliteDb) : IO (Except String Unit) := do
  return (← execParamQuery db
    "CREATE TABLE IF NOT EXISTS pending_mission_rebinds (mission_id TEXT PRIMARY KEY NOT NULL, owner_user_id TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT '');" #[]).map (fun _ => ())

/-- Called only by the placement transaction's beforeCommit hook. -/
def mark (st : CoreStore) (ids : Array String) (owner now : String) : IO (Except String Unit) := do
  for id in ids do
    if let .error e ← execParamQueryUnlocked st.missionsDb
        "INSERT OR REPLACE INTO pending_mission_rebinds VALUES(?1,?2,?3);" #[id, owner, now] then
      return .error e
  return .ok ()

def pending (db : SqliteDb) : IO (Except String (Array String)) := do
  return (← execParamQuery db "SELECT mission_id FROM pending_mission_rebinds ORDER BY mission_id;" #[]).map
    (fun rows => (rows.extract 1 rows.size).map (fun row => row[0]!))

/-- Serialize replay with placement commits. Always read the current destination,
    including when a later move superseded a pending one. Keep the marker on failure. -/
def reconcile (st : CoreStore) : IO (Except String Unit) := do
  if let .error e ← ensureSchema st.missionsDb then return .error e
  withImmediateTx st.missionsDb do
    let .ok rows ← execParamQueryUnlocked st.missionsDb
      ("SELECT p.mission_id,COALESCE(m.project,''),COALESCE(m.folder,''),COALESCE(m.placement_revision,0)," ++
       "p.owner_user_id,p.created_at FROM pending_mission_rebinds p LEFT JOIN missions m ON m.id=p.mission_id ORDER BY p.mission_id;") #[]
      | return .error "pending_rebind_read_failed"
    for row in rows.extract 1 rows.size do
      let id := row[0]!
      let project := row[1]!
      let owner := row[4]!
      if !project.isEmpty && !owner.isEmpty then
        if let .error e ← execParamQuery st.projectsDb
            "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
            #[project, owner, row[5]!] then return .error s!"{id}: {e}"
      let item : MissionPlacementItem := {
        missionId := id, project? := if project.isEmpty then none else some project,
        folder := row[2]!, placementRevision := (row[3]!.toNat?.getD 0).toUInt64 }
      if let .error e ← rebindMovedMissionMcpSessionsChecked st #[item] row[5]! then
        return .error s!"{id}: {e}"
      if let .error e ← execParamQueryUnlocked st.missionsDb
          "DELETE FROM pending_mission_rebinds WHERE mission_id=?1;" #[id] then
        return .error s!"{id}: {e}"
    return .ok ()

/-- Pre-server recovery deliberately avoids openCoreStore: no boot epoch allocation,
    lease recovery, or unrelated migrations. Borrow missionsDb for the unused
    idempotencyDb field and close each distinct handle exactly once. -/
def startup (root : String) : IO Unit := do
  let mut ids : Array String := #[]
  try
    let preferred ← IO.getEnv "SANDBOXED_SINGLE_TENANT_USER_ID"
    let fallback ← IO.getEnv "SINGLE_TENANT_USER_ID"
    let tenant := (preferred.filter (fun s => !s.trimAscii.isEmpty)).getD (fallback.getD "")
    let (mp, ap) ← resolveCoreStoreDbPaths root tenant
    if !(← (System.FilePath.mk mp).pathExists) then return
    let .ok m ← openSqliteDb mp "SELECT 1;" | throw (IO.userError "missions database open failed")
    try
      let .ok () ← ensureSchema m | throw (IO.userError "marker schema failed")
      let .ok pendingIds ← pending m | throw (IO.userError "marker read failed")
      ids := pendingIds
      if ids.isEmpty then return
      let .ok p ← openSqliteDb s!"{root}/projects.db" "SELECT 1;"
        | throw (IO.userError "projects database open failed")
      try
        let .ok a ← openSqliteDb ap "SELECT 1;" | throw (IO.userError "ask database open failed")
        try
          let closedRef ← IO.mkRef false
          let st : CoreStore := {
            rootDir := root
            missionsDb := m
            projectsDb := p
            askDb := a
            idempotencyDb := m
            closedRef := closedRef
          }
          if let .error e ← reconcile st then throw (IO.userError e)
        finally sqliteCloseRaw a.handle
      finally sqliteCloseRaw p.handle
    finally sqliteCloseRaw m.handle
  catch e =>
    IO.eprintln s!"[orb-core] pending mission rebind recovery failed; mission_ids={ids}: {e}"

end OrbCore.MissionMoveRecovery
