import OrbCore.Store
import OrbCore.SecretAndApproval

namespace OrbCore.MissionMoveRecovery

open OrbCore.Store OrbBin.Sqlite

def ensureSchema (db : SqliteDb) : IO (Except String Unit) := do
  if let .error e ← execParamQuery db
    "CREATE TABLE IF NOT EXISTS pending_mission_rebinds (mission_id TEXT PRIMARY KEY NOT NULL, owner_user_id TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT '');" #[] then return .error e
  return (← execParamQuery db "CREATE TABLE IF NOT EXISTS pending_move_policies (seq INTEGER PRIMARY KEY, mission_id TEXT NOT NULL, target TEXT NOT NULL, policy TEXT NOT NULL CHECK(policy IN ('keep','revoke')), applied_at TEXT NOT NULL, epoch INTEGER NOT NULL);" #[]).map (fun _ => ())

structure PolicyIntent where
  ids : Array String := #[]
  target : String := ""
  policy : String := "check"
  epoch : UInt64 := 0

/-- Called only by the placement transaction's beforeCommit hook. -/
def mark (st : CoreStore) (ids : Array String) (owner now : String) (intent : PolicyIntent := {}) : IO (Except String Unit) := do
  for id in ids do
    if let .error e ← execParamQueryUnlocked st.missionsDb
        "INSERT OR REPLACE INTO pending_mission_rebinds VALUES(?1,?2,?3);" #[id, owner, now] then
      return .error e
    if intent.ids.contains id && (intent.policy == "keep" || intent.policy == "revoke") then
      if let .error e ← execParamQueryUnlocked st.missionsDb
          "INSERT INTO pending_move_policies(mission_id,target,policy,applied_at,epoch) VALUES(?1,?2,?3,?4,?5);"
          #[id, intent.target, intent.policy, now, toString intent.epoch] then return .error e
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
      ("SELECT p.mission_id,m.id,COALESCE(m.project,''),COALESCE(m.folder,''),COALESCE(m.placement_revision,0)," ++
       "p.owner_user_id,p.created_at FROM pending_mission_rebinds p LEFT JOIN missions m ON m.id=p.mission_id ORDER BY p.mission_id;") #[]
      | return .error "pending_rebind_read_failed"
    let allIds := (rows.extract 1 rows.size).map (fun row => row[0]!)
    let failure (id : String) (e : String) : String :=
      let commands := allIds.map fun stuckId =>
        "DELETE FROM pending_mission_rebinds WHERE mission_id='" ++ stuckId.replace "'" "''" ++ "';"
      s!"mission_ids={allIds}; {id}: {e}; manual bypass on missions.db (leaves bindings unrepaired): {String.intercalate " " commands.toList}"
    -- Grants may match either a root or a child: replay across all missions in commit order.
    let .ok policies ← execParamQueryUnlocked st.missionsDb
      "SELECT p.mission_id,p.target,p.policy,p.applied_at,p.epoch FROM pending_move_policies p JOIN missions m ON m.id=p.mission_id ORDER BY p.seq;" #[]
      | return .error "move_policy_read_failed"
    for p in policies.extract 1 policies.size do
      let some epoch := p[4]!.toNat? | return .error (failure p[0]! "move_policy_epoch_invalid")
      if let .error e ← OrbCore.SecretAndApproval.applyCrossProjectSecretPolicy st.rootDir #[p[0]!] p[1]! p[2]! p[3]! epoch.toUInt64 then
        return .error (failure p[0]! e)
    if let .error e ← execParamQueryUnlocked st.missionsDb "DELETE FROM pending_move_policies;" #[] then return .error e
    for row in rows.extract 1 rows.size do
      let id := row[0]!
      let hasMission := !row[1]!.isEmpty
      let project := row[2]!
      let owner := row[5]!
      if !hasMission then
        if let .error e ← execParamQueryUnlocked st.missionsDb
            "DELETE FROM pending_mission_rebinds WHERE mission_id=?1;" #[id] then
          return .error (failure id e)
        continue
      if !project.isEmpty && !owner.isEmpty then
        if let .error e ← execParamQuery st.projectsDb
            "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES(?1,?2,?3);"
            #[project, owner, row[6]!] then return .error (failure id e)
      let item : MissionPlacementItem := {
        missionId := id, project? := if project.isEmpty then none else some project,
        folder := row[3]!, placementRevision := (row[4]!.toNat?.getD 0).toUInt64 }
      if let .error e ← rebindMovedMissionMcpSessionsChecked st #[item] row[6]! then
        return .error (failure id e)
      if let .error e ← execParamQueryUnlocked st.missionsDb
          "DELETE FROM pending_mission_rebinds WHERE mission_id=?1;" #[id] then
        return .error (failure id e)
    return .ok ()

/-- Pre-server recovery deliberately avoids openCoreStore: no boot epoch allocation,
    lease recovery, or unrelated migrations. Borrow missionsDb for the unused
    idempotencyDb field and close each distinct handle exactly once. -/
private def attemptStartup (root : String) : IO (Except String Unit) := do
  let mut ids : Array String := #[]
  let mut markerDbPath := ""
  try
    let preferred ← IO.getEnv "SANDBOXED_SINGLE_TENANT_USER_ID"
    let fallback ← IO.getEnv "SINGLE_TENANT_USER_ID"
    let tenant := (preferred.filter (fun s => !s.trimAscii.isEmpty)).getD (fallback.getD "")
    let (mp, ap) ← resolveCoreStoreDbPaths root tenant
    markerDbPath := mp
    if !(← (System.FilePath.mk mp).pathExists) then return .ok ()
    let .ok m ← openSqliteDb mp "SELECT 1;" | throw (IO.userError "missions database open failed")
    try
      let .ok () ← ensureSchema m | throw (IO.userError "marker schema failed")
      let .ok pendingIds ← pending m | throw (IO.userError "marker read failed")
      ids := pendingIds
      if ids.isEmpty then return .ok ()
      if !(← (System.FilePath.mk s!"{root}/projects.db").pathExists) then
        return .error s!"mission_ids={ids}; step=projects-open; projects database is missing"
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
          if let .error e ← reconcile st then throw (IO.userError s!"step=reconcile: {e}")
          return .ok ()
        finally sqliteCloseRaw a.handle
      finally sqliteCloseRaw p.handle
    finally sqliteCloseRaw m.handle
  catch e =>
    -- Preserve the operator-facing id list even when the failure happened
    -- after the first marker read (or when a nested exception discarded the
    -- local result).  The DELETE commands are the only supported bypass.
    if ids.isEmpty && !markerDbPath.isEmpty && (← (System.FilePath.mk markerDbPath).pathExists) then
      try
        let .ok m ← openSqliteDb markerDbPath "SELECT 1;" | throw (IO.userError "marker database reopen failed")
        try
          match ← pending m with
          | .ok found => ids := found
          | .error _ => pure ()
        finally sqliteCloseRaw m.handle
      catch _ => pure ()
    let commands := ids.map fun id =>
      "DELETE FROM pending_mission_rebinds WHERE mission_id='" ++ id.replace "'" "''" ++ "';"
    return .error s!"mission_ids={ids}; step=startup-open-or-reconcile; error={e}; manual bypass on missions.db (leaves bindings unrepaired): {String.intercalate " " commands.toList}"

/-- Each SQLite statement waits up to 5000 ms for locks. Retry the entire
    idempotent pass three times, one second apart, then refuse server startup. -/
def startup (root : String) : IO (Except String Unit) := do
  let mut last := "recovery failed"
  for attempt in [0:3] do
    match ← attemptStartup root with
    | .ok () => return .ok ()
    | .error e => last := e
    if attempt < 2 then IO.sleep 1000
  return .error last

/-- The CLI and tests share the actual recovery-to-server admission branch. -/
def startAfterRecovery (root : String) (serve : IO UInt32) : IO UInt32 := do
  match ← startup root with
  | .ok () => serve
  | .error e =>
    IO.eprintln s!"[orb-core] startup move recovery refused to start: {e}"
    return 1

end OrbCore.MissionMoveRecovery
