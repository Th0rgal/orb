import OrbCore.Control

namespace OrbCore.HungNodeTests

open OrbBin.PosixExt OrbCore.Store OrbCore.RemoteDispatch

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"hung node: {label}")

private def cellOf (db : OrbBin.Sqlite.SqliteDb) (sql : String) (params : Array String) : IO String := do
  let .ok rows ← execParamQuery db sql params | throw (IO.userError "hung node: query failed")
  return (rows[1]?.bind (·[0]?)).getD ""

def run : IO Unit := do
  let root := s!"/tmp/orb-hung-node-{← newUuidV4}"
  try
    let .ok store ← openCoreStore root | throw (IO.userError "hung node: store open failed")
    try
      let now ← coreEpochSec
      for (mid, status) in #[("m-hung-active", "active"), ("m-hung-finished", "completed")] do
        let .ok _ ← execParamQuery store.missionsDb
            ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
             "VALUES(?1,'hung',?2,'opencode','', '', 'managed','[]',1,1,'t0','t0');") #[mid, status]
          | throw (IO.userError "hung node: mission fixture failed")
      let .ok _ ← execParamQuery store.missionsDb
          ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) " ++
           "VALUES('run-hung','m-hung-active',1,'running','','job-hung','t0');") #[]
        | throw (IO.userError "hung node: run fixture failed")
      let recovered ← wakeHungMissions store none none now
      check (recovered == 1) "only the active mission with live work is recovered"
      check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-hung-active';" #[]) == "awaiting_user")
        "a live active mission is parked for recovery"
      check ((← cellOf store.missionsDb "SELECT terminal_reason FROM missions WHERE id='m-hung-active';" #[]) == "hung_node")
        "the recovery is visibly flagged"
      check ((← cellOf store.missionsDb "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-hung-active' AND phase=1;" #[]) == "1")
        "exactly one recovery wake-up is armed"
      check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-hung-finished';" #[]) == "completed")
        "a finished mission without live work is untouched"
      check ((← wakeHungMissions store none none (now + 1)) == 0)
        "the watchdog is idempotent after arming"
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root

end OrbCore.HungNodeTests
