/-
  A scheduled wake-up must survive a Core restart and a failed launch:
  it fires late, never not at all. No node, harness or network is used.
-/
import OrbCore.Control

namespace OrbCore.WakeupRestartTests
open OrbBin.Sqlite OrbBin.PosixExt
open OrbCore.Store OrbCore.RemoteDispatch

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"wakeup restart: {label}")

private def cellOf (db : SqliteDb) (sql : String) (params : Array String) : IO String := do
  let .ok rows ← execParamQuery db sql params | throw (IO.userError s!"query failed: {sql}")
  return (rows[1]?.bind (·[0]?)).getD ""

def run : IO Unit := do
  let root := s!"/tmp/orb-wakeup-restart-{← newUuidV4}"
  let due : UInt64 := 1700003600
  try
    let .ok first ← openCoreStore root | throw (IO.userError "wakeup store open failed")
    -- A local turn is in flight (mission active, no run row) with a wake-up armed for later,
    -- and a second mission waits on a job wake-up armed with its far deadline.
    for (mid, status) in #[("m-wk-time", "active"), ("m-wk-job", "awaiting_user")] do
      let .ok _ ← execParamQuery first.missionsDb
          ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
           "VALUES(?1,'wakeup',?2,'claudecode','','','managed','[]',1,CAST(?3 AS INTEGER),'t0','t0');") #[mid, status, s!"{first.bootEpoch}"]
        | throw (IO.userError "wakeup mission insert failed")
    for (cid, mid, kind, dueAt, job) in #[
        ("c-time", "m-wk-time", "time", due, ""), ("c-job", "m-wk-job", "durable_job_terminal", due + 86400, "job-done")] do
      let .ok _ ← execParamQuery first.missionsDb
          ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
           "VALUES(?1,?2,1,1,CAST(?3 AS INTEGER),?4,'test','continue',?1,?5,'mcp','','',1,'t0','t0');") #[cid, mid, s!"{dueAt}", kind, job]
        | throw (IO.userError "wakeup continuation insert failed")
    let bootBefore := first.bootEpoch
    closeCoreStore first
    -- Core restarts before the due time.
    let .ok store ← openCoreStore root | throw (IO.userError "wakeup store reopen failed")
    try
      check (store.bootEpoch == bootBefore + 1) "reopen must be a new boot"
      check ((← cellOf store.missionsDb "SELECT phase FROM mission_continuations WHERE id='c-time';" #[]) == "1")
        "armed wake-up must survive the restart"
      check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-wk-time';" #[]) == "active")
        "opening the store alone (CLI, second process) must not touch a running turn"
      -- What the server does once its listen socket is bound.
      check ((← interruptTurnsLostToRestart store.missionsDb) == 1) "exactly the lost turn is marked"
      check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-wk-time';" #[]) == "interrupted")
        "a turn lost to the restart must not leave the mission active"
      let sup ← newRemoteJobSupervisor "wakeup-restart-fixture-secret" false
      let launches ← IO.mkRef (#[] : Array String)
      let succeed ← IO.mkRef false
      let launch : MissionRecord → String → Option String → IO Bool := fun mr _ _ => do
        launches.modify (·.push mr.id)
        succeed.get
      let tick := fun (now : UInt64) =>
        discard <| tickContinuationScheduler store none none none sup none root (some launch) (some now)
      tick (due - 1)
      check ((← launches.get).isEmpty) "nothing fires before it is due"
      -- Due, but the launch fails: the wake-up is kept and retried, not consumed.
      tick (due + 1)
      check ((← launches.get) == #["m-wk-time"]) "the due wake-up fires after the restart"
      check ((← cellOf store.missionsDb "SELECT phase || ':' || error FROM mission_continuations WHERE id='c-time';" #[]) == "1:launch_retry:1")
        "a failed launch re-arms the wake-up"
      check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-wk-time';" #[]) != "active")
        "a failed launch must not leave the mission active"
      tick (due + 2)
      check ((← launches.get).size == 1) "the retry waits for its backoff"
      succeed.set true
      tick (due + 120)
      check ((← launches.get) == #["m-wk-time", "m-wk-time"]) "the retry fires late"
      check ((← cellOf store.missionsDb "SELECT phase FROM mission_continuations WHERE id='c-time';" #[]) == "4")
        "a launched one-shot wake-up is retired"
      tick (due + 5000)
      check ((← launches.get).size == 2) "a retired wake-up never fires twice"
      -- Job wake-up: not due while the job runs, due as soon as it is terminal.
      let .ok _ ← execParamQuery store.missionsDb
          "CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, state TEXT NOT NULL DEFAULT '');" #[]
        | throw (IO.userError "job table")
      let .ok _ ← execParamQuery store.missionsDb
          "INSERT OR REPLACE INTO remote_node_jobs(job_id,state) VALUES('job-done','succeeded');" #[]
        | throw (IO.userError "job row")
      tick (due + 5001)
      check ((← launches.get).back? == some "m-wk-job") "a job wake-up fires when its job is terminal"
      -- A job wake-up whose launch fails backs off like any other, then is retired with an error.
      succeed.set false
      let .ok _ ← execParamQuery store.missionsDb
          ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
           "SELECT 'c-job2',id,run_generation,1,CAST(?1 AS INTEGER),'durable_job_terminal','test','continue','c-job2','job-done','mcp','','',1,'t0','t0' FROM missions WHERE id='m-wk-job';")
          #[s!"{due + 200000}"]
        | throw (IO.userError "wakeup second job continuation insert failed")
      let before := (← launches.get).size
      tick (due + 6000)
      tick (due + 6002)
      check ((← launches.get).size == before + 1) "a failed job wake-up waits for its backoff"
      let mut now := due + 6002
      for _ in [0:maxWakeupLaunchTries + 2] do
        now := now + 1000
        tick now
      check ((← launches.get).size == before + maxWakeupLaunchTries) "launch attempts are bounded"
      check ((← cellOf store.missionsDb "SELECT phase || ':' || error FROM mission_continuations WHERE id='c-job2';" #[]) == "4:launch_failed")
        "an abandoned wake-up is retired with a stated error"
      check ((← cellOf store.missionsDb "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-wk-job' AND event_type='user_message';" #[]) == "2")
        "one transcript entry per wake-up, not per attempt"
      -- An ordinary follow-up turn keeps the next wake-up; older generations stay fenced.
      let .ok _ ← execParamQuery store.missionsDb
          ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
           "VALUES('m-follow','wakeup','awaiting_user','claudecode','','','managed','[]',3,1,'t0','t0');") #[]
        | throw (IO.userError "follow-up mission insert failed")
      for (cid, gen, phase, source) in #[("f-keep", "3", "1", "mcp"), ("f-old", "2", "1", "mcp"),
          ("f-retry", "3", "1", "empty-turn-retry"), ("f-fired", "3", "2", "mcp")] do
        let .ok _ ← execParamQuery store.missionsDb
            ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
             "VALUES(?1,'m-follow',CAST(?2 AS INTEGER),CAST(?3 AS INTEGER),1900000000,'time','test','continue',?1,'',?4,'','',1,'t0','t0');") #[cid, gen, phase, source]
          | throw (IO.userError "follow-up continuation insert failed")
      OrbCore.QueueCont.carryArmedWakeupsForward (execParamQuery store.missionsDb) "m-follow" 4 "t1"
      check ((← cellOf store.missionsDb "SELECT group_concat(id || ':' || run_generation || ':' || phase, ' ') FROM (SELECT * FROM mission_continuations WHERE mission_id='m-follow' ORDER BY id);" #[])
          == "f-fired:3:2 f-keep:4:1 f-old:2:3 f-retry:3:3")
        "a follow-up turn carries the armed wake-up forward and fences the rest"
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root

end OrbCore.WakeupRestartTests
