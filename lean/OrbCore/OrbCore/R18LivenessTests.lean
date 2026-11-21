import OrbCore.Managed
import OrbCore.Store

namespace OrbCore.R18LivenessTests

open OrbCore.Store OrbCore.Managed

private def require {α : Type} (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error error => throw (IO.userError error)

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"r18 liveness: {label}")

private def missionSql (db : SqliteDb) (id status placementKind : String) (gen : Nat) : IO Unit := do
  discard <| require (← execParamQuery db
    ("INSERT INTO missions(id,title,status,backend,working_directory,placement_kind,run_generation,updated_at) " ++
     "VALUES(?1,'r18',?2,'codex','/tmp',?3,CAST(?4 AS INTEGER),'2026-01-01T00:00:00Z');")
    #[id, status, placementKind, s!"{gen}"])

private def addRun (db : SqliteDb) (id mission gen state : String) : IO Unit := do
  discard <| require (← execParamQuery db
    ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) " ++
     "VALUES(?1,?2,CAST(?3 AS INTEGER),?4,'','', '2026-01-01T00:00:00Z');")
    #[id, mission, gen, state])

private def count (db : SqliteDb) (sql : String) (params : Array String := #[]) : IO Nat := do
  let rows ← require (← execParamQuery db sql params)
  pure (if rows.size > 1 then ((rows[1]![0]?).bind String.toNat?).getD 0 else 0)

/-- Restart must mark only genuinely ownerless active turns, emit one durable
    receipt, leave live runs and client-owned turns alone, and the periodic
    backstop must reap a run whose mission already ended. -/
def recoveryAndOrphanReaping (root : String) : IO Unit := do
  let .ok store ← openCoreStore root
    | throw (IO.userError "r18 liveness: open core store")
  try
    missionSql store.missionsDb "m-lost" "active" "managed" 1
    missionSql store.missionsDb "m-live" "active" "managed" 1
    missionSql store.missionsDb "m-client" "active" "client" 1
    missionSql store.missionsDb "m-done" "completed" "managed" 1
    addRun store.missionsDb "r-live" "m-live" "1" "running"
    addRun store.missionsDb "r-done" "m-done" "1" "running"
    let archive ← setMissionStatusFromClient store "m-lost" "acknowledged" "2026-01-01T00:00:01Z"
    match archive with
    | .error e => check (e == "mission_running") "archive refuses an activated mission before its run is recorded"
    | .ok _ => throw (IO.userError "archive overwrote a live mission before run insertion")
    let lost ← interruptTurnsLostToRestart store.missionsDb
    check (lost == 1) "restart marks exactly one ownerless active mission"
    let receipts ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-lost' AND event_type='recovery_receipt';"
    check (receipts == 1) "restart writes one recovery receipt for the lost turn"
    let lostStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-lost' AND status='interrupted' AND terminal_reason='core_restarted';"
    check (lostStatus == 1) "lost mission is interrupted with core_restarted"
    let liveStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-live' AND status='active';"
    check (liveStatus == 1) "mission with a durable live run is not interrupted"
    let clientStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-client' AND status='active';"
    check (clientStatus == 1) "client-owned turn is not interrupted by Core restart"
    let reaped ← reapOrphanedMissionRuns store.missionsDb "2026-01-01T00:01:00Z"
    check (reaped == 1) "periodic backstop reaps exactly the run whose mission ended"
    let doneRun ← count store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE id='r-done' AND execution_state='terminal' AND terminal_reason='orphaned_scope';"
    check (doneRun == 1) "orphaned run is terminal with orphaned_scope"
    let liveRun ← count store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE id='r-live' AND execution_state='running';"
    check (liveRun == 1) "run of a live mission is untouched"
  finally closeCoreStore store

/-- A child mission must be admitted against its ancestor's dollar pool even
    when the managed database has no mission-tree table of its own. -/
def lineageMissionBudget (root : String) : IO Unit := do
  let .ok core ← openCoreStore root
    | throw (IO.userError "r18 liveness: open core store")
  try
    missionSql core.missionsDb "parent" "active" "managed" 1
    missionSql core.missionsDb "child" "active" "managed" 1
    discard <| require (← execParamQuery core.missionsDb
      "UPDATE missions SET parent_mission_id='parent' WHERE id='child';" #[])
    let .ok mc ← openManagedComputeStore s!"{root}/managed.db" (some core.missionsDb)
      | throw (IO.userError "r18 liveness: open managed store")
    try
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "parent", budgetDeciMilliUsd? := some 100 })
      discard <| require (← saveManagedFleetConfig mc true true 100 0 10)
      let fleet : ManagedFleetState :=
        { enabled := true, boatEnabled := true, dailyCapCents := 100, spentTodayCents := 0, maxConcurrent := 10 }
      let machine : ManagedMachine :=
        { id := "child-vm", sandboxName := "orb-managed-child-vm", size := "small",
          ownerMission := "child", ttlMinutes := 60, spentCents := 2 }
      match ← provisionManagedMachine mc fleet machine 1700000000 with
      | .ok _ => throw (IO.userError "r18 liveness: over-budget child admission succeeded")
      | .error e =>
        check (e == "mission_budget_exceeded:parent")
          s!"child admission names the exhausted ancestor pool (got {e})"
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "parent", budgetDeciMilliUsd? := some 1000 })
      match ← provisionManagedMachine mc fleet machine 1700000001 with
      | .ok _ => pure ()
      | .error e => throw (IO.userError s!"r18 liveness: funded child admission failed: {e}")
    finally closeManagedComputeStore mc
  finally closeCoreStore core

end OrbCore.R18LivenessTests
