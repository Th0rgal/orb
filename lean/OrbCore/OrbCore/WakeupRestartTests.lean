/-
  A scheduled wake-up must survive a Core restart and a failed launch:
  it fires late, never not at all. All state and launcher inputs are isolated.
-/
import OrbCore.Control

namespace OrbCore.WakeupRestartTests
open OrbBin.Sqlite OrbBin.PosixExt
open OrbCore.Store OrbCore.RemoteDispatch
open OrbCore.QueueCont OrbCore.Control

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"wakeup restart: {label}")

private def cellOf (db : SqliteDb) (sql : String) (params : Array String) : IO String := do
  let .ok rows ← execParamQuery db sql params | throw (IO.userError s!"query failed: {sql}")
  return (rows[1]?.bind (·[0]?)).getD ""

private def sql (db : SqliteDb) (stmt : String) (params : Array String := #[]) : IO Unit := do
  let .ok _ ← execParamQuery db stmt params | throw (IO.userError s!"fixture setup failed: {stmt}")

private def verifyLegacyMigration (store : CoreStore) (now : UInt64) : IO Unit := do
  let db := store.missionsDb
  sql db ("CREATE TABLE automations(id TEXT PRIMARY KEY,mission_id TEXT,command_source_type TEXT DEFAULT 'inline', " ++
    "command_source_data TEXT,trigger_type TEXT,trigger_data TEXT,variables TEXT DEFAULT '{}',stop_policy TEXT, " ++
    "fresh_session TEXT DEFAULT 'keep',driver TEXT DEFAULT 'scheduler',active INTEGER);")
  sql db "CREATE TABLE mission_wakeup_fences(mission_id TEXT PRIMARY KEY, stopped_generation INTEGER NOT NULL);"
  let unsupported : Array (String × String × String × String × String × String × String × String × String) := #[
    ("unknown", "inline", "{\"content\":\"legacy intent\"}", "future_trigger", "{\"job_id\":\"unrelated\"}", "{}", "never", "keep", "scheduler"),
    ("cron", "inline", "{\"content\":\"legacy intent\"}", "cron", "{\"expression\":\"0 0 * * *\"}", "{}", "after_first_fire", "keep", "scheduler"),
    ("webhook", "inline", "{\"content\":\"legacy intent\"}", "webhook", "{\"path\":\"/hook\"}", "{}", "after_first_fire", "keep", "scheduler"),
    ("agent-fin", "inline", "{\"content\":\"legacy intent\"}", "agent_finished", "{}", "{}", "after_first_fire", "keep", "scheduler"),
    ("telegram", "inline", "{\"content\":\"legacy intent\"}", "telegram", "{\"chat_id\":1}", "{}", "after_first_fire", "keep", "scheduler"),
    ("empty-trig", "inline", "{\"content\":\"legacy intent\"}", "", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("policy", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "consecutive_failures:2", "keep", "scheduler"),
    ("term-done", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "when_mission_terminal", "keep", "scheduler"),
    ("cmd-lib", "library", "{\"name\":\"nightly\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-file", "local_file", "{\"path\":\"/tmp/run.md\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-loop", "native_loop", "{\"harness\":\"codex\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-obj", "inline", "{\"name\":\"not-inline-content\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-badjson", "inline", "{\"content\":\"broken", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-empty", "inline", "", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("cmd-noninline-type", "inline", "{\"type\":\"library\",\"content\":\"sneaky\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("drv-loop", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "harness_loop"),
    ("fresh-sw", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "always", "scheduler"),
    ("has-vars", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{\"env\":\"prod\"}", "after_first_fire", "keep", "scheduler"),
    ("stale-wgen", "inline", "{\"content\":\"stale wakeup\"}", "interval", "{\"seconds\":300}", "{\"__wakeup_request_id\":\"req-stale\",\"__wakeup_run_generation\":\"1\",\"__wakeup_source\":\"mcp\"}", "after_first_fire", "keep", "scheduler"),
    ("fenced-wgen", "inline", "{\"content\":\"fenced wakeup\"}", "interval", "{\"seconds\":300}", "{\"__wakeup_request_id\":\"req-fenced\",\"__wakeup_run_generation\":\"2\",\"__wakeup_source\":\"mcp\"}", "after_first_fire", "keep", "scheduler"),
    ("bad-json", "inline", "{\"content\":\"legacy intent\"}", "interval", "not-json", "{}", "after_first_fire", "keep", "scheduler"),
    ("bad-at", "inline", "{\"content\":\"legacy intent\"}", "time", "{\"at\":\"not-a-date\",\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("bad-insert", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("bad-retire", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler")
  ]
  let supported : Array (String × String × String × String × String × String × String × String × String) := #[
    ("valid", "inline", "{\"content\":\"legacy intent\"}", "interval", "{\"seconds\":300}", "{}", "after_first_fire", "keep", "scheduler"),
    ("valid-recur", "inline", "{\"content\":\"recurring intent\"}", "interval", "{\"seconds\":300}", "{}", "never", "keep", "scheduler"),
    ("valid-job", "inline", "{\"content\":\"job intent\"}", "durable_job_terminal", "{\"job_id\":\"job-leg-1\"}", "{}", "after_first_fire", "keep", "scheduler"),
    ("valid-wakeup-meta", "inline", "{\"content\":\"meta wakeup\"}", "interval", "{\"seconds\":300}", "{\"__wakeup_request_id\":\"req-meta-1\",\"__wakeup_reason\":\"poll\",\"__wakeup_source\":\"mcp\",\"__wakeup_run_generation\":\"2\"}", "after_first_fire", "keep", "scheduler")
  ]
  for (aid, cmdType, cmdData, kind, payload, vars, policy, fresh, drv) in unsupported ++ supported do
    let mGen := if aid == "stale-wgen" || aid == "fenced-wgen" || aid == "valid-wakeup-meta" then "2" else "1"
    sql db "INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) VALUES(?1,'legacy','completed','claudecode',CAST(?2 AS INTEGER),'t0','t0');" #[s!"m-legacy-{aid}", mGen]
    sql db "INSERT INTO automations VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1);"
      #[aid, s!"m-legacy-{aid}", cmdType, cmdData, kind, payload, vars, policy, fresh, drv]
  sql db "INSERT INTO mission_wakeup_fences(mission_id,stopped_generation) VALUES('m-legacy-fenced-wgen',2);"
  -- SQL NULL command_source_data and archived (acknowledged) owning mission must both stay intact.
  sql db "INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) VALUES('m-legacy-cmd-null','legacy','completed','claudecode',1,'t0','t0');"
  sql db "INSERT INTO automations(id,mission_id,command_source_type,command_source_data,trigger_type,trigger_data,variables,stop_policy,fresh_session,driver,active) VALUES('cmd-null','m-legacy-cmd-null','inline',NULL,'interval','{\"seconds\":300}','{}','after_first_fire','keep','scheduler',1);"
  sql db "INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) VALUES('m-legacy-archived','legacy','acknowledged','claudecode',1,'t0','t0');"
  sql db "INSERT INTO automations VALUES('archived','m-legacy-archived','inline','{\"content\":\"archived intent\"}','interval','{\"seconds\":300}','{}','after_first_fire','keep','scheduler',1);"
  sql db ("CREATE TRIGGER reject_legacy_insert BEFORE INSERT ON mission_continuations " ++
    "WHEN NEW.id='leg-auto-bad-insert' BEGIN SELECT RAISE(ABORT,'fixture insert failure'); END;")
  sql db ("CREATE TRIGGER reject_legacy_retirement BEFORE UPDATE ON automations " ++
    "WHEN OLD.id='bad-retire' BEGIN SELECT RAISE(IGNORE); END;")
  let totalSkipped := unsupported.size + 2
  check ((← migrateLegacyAutomations store now) == supported.size && (← migrateLegacyAutomations store now) == 0)
    "only supported, fully written sources migrate, once"
  check ((← cellOf db "SELECT COUNT(*) FROM automations WHERE active=1 AND id NOT IN ('valid','valid-recur','valid-job','valid-wakeup-meta');" #[]) == s!"{totalSkipped}")
    "unsupported triggers, unsupported intent, archived missions, fenced metadata, and failed writes retain their active source"
  check ((← cellOf db "SELECT COUNT(*) FROM missions WHERE id LIKE 'm-legacy-%' AND status='completed';" #[]) == s!"{unsupported.size + 1}")
    "skipped rows and failed writes do not park completed owning missions"
  check ((← cellOf db "SELECT status FROM missions WHERE id='m-legacy-archived';" #[]) == "acknowledged")
    "archived missions stay acknowledged during legacy migration"
  check ((← cellOf db "SELECT group_concat(id || ':' || trigger_kind || ':' || prompt || ':' || stop_after_first || ':' || recurrence || ':' || request_id, '|') FROM (SELECT * FROM mission_continuations WHERE source='legacy-automations-migration' ORDER BY id);" #[]) ==
    "leg-auto-valid:time:legacy intent:1::legacy-automation:valid|leg-auto-valid-job:durable_job_terminal:job intent:1::legacy-automation:valid-job|leg-auto-valid-recur:time:recurring intent:0:interval:300:legacy-automation:valid-recur|leg-auto-valid-wakeup-meta:time:meta wakeup:1::req-meta-1")
    "supported legacy one-shot, recurring, durable-job, and __wakeup_* automations preserve exact intent"
  -- Single-column `command_source` legacy schema: non-inline `"type"` stays intact, inline migrates.
  let singleRoot := s!"/tmp/orb-wakeup-singlecmd-{← newUuidV4}"
  try
    let .ok singleStore ← openCoreStore singleRoot | throw (IO.userError "single-cmd store open")
    try
      let sdb := singleStore.missionsDb
      sql sdb "CREATE TABLE automations(id TEXT PRIMARY KEY,mission_id TEXT,command_source TEXT,trigger_type TEXT,trigger_data TEXT,stop_policy TEXT,active INTEGER);"
      sql sdb "INSERT INTO missions(id,title,status,backend,created_at,updated_at) VALUES('m-sc-bad','legacy','completed','claudecode','t0','t0');"
      sql sdb "INSERT INTO automations VALUES('sc-bad','m-sc-bad','{\"type\":\"library\",\"content\":\"do not flatten\"}','interval','{\"seconds\":300}','after_first_fire',1);"
      sql sdb "INSERT INTO missions(id,title,status,backend,created_at,updated_at) VALUES('m-sc-ok','legacy','completed','claudecode','t0','t0');"
      sql sdb "INSERT INTO automations VALUES('sc-ok','m-sc-ok','{\"type\":\"inline\",\"content\":\"inline ok\"}','interval','{\"seconds\":300}','after_first_fire',1);"
      check ((← migrateLegacyAutomations singleStore now) == 1) "single-column command_source migrates only inline type"
      check ((← cellOf sdb "SELECT active FROM automations WHERE id='sc-bad';" #[]) == "1" &&
        (← cellOf sdb "SELECT status FROM missions WHERE id='m-sc-bad';" #[]) == "completed")
        "single-column non-inline command_source leaves source and mission intact"
    finally
      closeCoreStore singleStore
  finally
    IO.FS.removeDirAll singleRoot

private def verifyProductionLocalFailure (store : CoreStore) (sup : RemoteJobSupervisor)
    (root : String) (due : UInt64) : IO Unit := do
  let db := store.missionsDb
  -- A stored native session makes the real launcher advance the generation
  -- before it discovers the deliberately missing CLI.
  sql db ("INSERT INTO missions(id,title,status,backend,session_id,run_generation,created_at,updated_at) " ++
    "VALUES('m-real-local','wakeup','interrupted',?1,'old-fixture-session',1,'t0','t0');") #[s!"missing-cli-{← newUuidV4}"]
  let .ok _ ← registerContinuation store
    { id := "c-real-local", missionId := "m-real-local", requestId := "real-local", prompt := "retry me",
      reason := "test", source := "mcp", triggerKind := "time", dueEpoch := due } (due - 1) "t0"
    | throw (IO.userError "production local continuation registration")
  let warmMgr ← OrbBin.ClaudeControl.newWarmHarnessManager
  let app : CoreAppState := {
    cfg := { workingDir := root }, store, searchIdx? := none, managedRef := ← IO.mkRef {},
    chainsRef := ← IO.mkRef #[], proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 0,
    warmMgr? := some warmMgr, remoteSup? := some sup }
  let tick := fun now => tickContinuationScheduler store none none none sup none root (some (launchLocalWakeup app)) (some now)
  let state := cellOf db ("SELECT c.phase||':'||c.run_generation||':'||c.error||':'||m.status||':'||m.run_generation " ++
    "FROM mission_continuations c JOIN missions m ON m.id=c.mission_id WHERE c.id='c-real-local';") #[]
  discard <| tick due
  check ((← state) == "1:2:launch_retry:1:interrupted:2") "real failed launch advances the generation and re-arms once"
  check ((← warmMgr.launchGenerations.get).get? "m-real-local" == none)
    "real failed launch clears its launch-generation slot"
  discard <| tick (due + 59)
  check ((← state) == "1:2:launch_retry:1:interrupted:2") "real retry respects its deadline"
  discard <| tick (due + 60)
  discard <| tick (due + 60)
  check ((← state) == "1:3:launch_retry:2:interrupted:3") "the real launcher retries once at the deadline"
  check ((← cellOf db "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-real-local' AND event_type='user_message';" #[]) == "1")
    "real retries do not duplicate the wake-up prompt"
  -- Replacing a re-armed wake-up clears its prior launch_retry count so the replacement
  -- gets its own transcript entry and full bounded retry budget.
  let repDue := due + 500
  let .ok repId ← registerContinuation store
    { id := "c-real-local-rep", missionId := "m-real-local", requestId := "real-local-rep", prompt := "fresh replacement",
      reason := "test", source := "mcp", triggerKind := "time", dueEpoch := repDue } (due + 61) "t1"
    | throw (IO.userError "production local continuation replacement")
  check (repId == "c-real-local") "time replacement reuses the armed row"
  check ((← cellOf db "SELECT error || ':' || dispatch_job_id FROM mission_continuations WHERE id='c-real-local';" #[]) == ":")
    "replacing a failed wake-up clears prior retry state"
  discard <| tick repDue
  check ((← state) == "1:4:launch_retry:1:interrupted:4") "replaced wake-up starts from launch_retry:1 after generation advance"
  check ((← cellOf db "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-real-local' AND event_type='user_message';" #[]) == "2")
    "replaced wake-up records its own user_message once"
  -- Bounded retries through the real production launcher: never spin infinitely.
  let mut t := repDue
  for _ in [0:maxWakeupLaunchTries + 2] do
    t := t + 1000
    discard <| tick t
  check ((← cellOf db "SELECT phase || ':' || error FROM mission_continuations WHERE id='c-real-local';" #[]) == "4:launch_failed")
    "real production launcher bounds retries and retires as launch_failed"
  check ((← cellOf db "SELECT status FROM missions WHERE id='m-real-local';" #[]) == "interrupted")
    "exhausted production local failures never strand a ghost-active mission"
  -- Proxied local failure: blocking `codex-home/<id>` with a regular file forces a pre-spawn
  -- exception AFTER `mintMissionProxyToken`, verifying exception handling and token revocation.
  let prevPort ← sup.boundPortRef.get
  sup.boundPortRef.set 18080
  try
    sql db ("INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) " ++
      "VALUES('m-real-proxy-fail','wakeup','awaiting_user','codex',1,'t0','t0');")
    IO.FS.createDirAll s!"{store.rootDir}/core-turns/codex-home"
    IO.FS.writeFile s!"{store.rootDir}/core-turns/codex-home/m-real-proxy-fail" "block-dir"
    let .ok _ ← registerContinuation store
      { id := "c-real-proxy-fail", missionId := "m-real-proxy-fail", requestId := "real-proxy-fail", prompt := "proxy fail",
        reason := "test", source := "mcp", triggerKind := "time", dueEpoch := t + 10 } t "t0"
      | throw (IO.userError "proxied local failure registration")
    discard <| tick (t + 10)
    check ((← cellOf db "SELECT c.phase||':'||c.run_generation||':'||c.error||':'||m.status||':'||m.run_generation FROM mission_continuations c JOIN missions m ON m.id=c.mission_id WHERE c.id='c-real-proxy-fail';" #[]) == "1:2:launch_retry:1:interrupted:2")
      "proxied pre-spawn setup exception settles mission and re-arms once"
    check ((← cellOf db "SELECT COUNT(*) FROM mission_proxy_tokens WHERE mission_id='m-real-proxy-fail' AND revoked=0;" #[]) == "0" &&
      (← cellOf db "SELECT COUNT(*) FROM mission_proxy_tokens WHERE mission_id='m-real-proxy-fail' AND revoked=1;" #[]) == "1")
      "proxied failed launch revokes its minted mission proxy token"
  finally
    sup.boundPortRef.set prevPort
  -- Job-wakeup replacement updates legacy `trigger_kind='job'` to `'durable_job_terminal'`.
  sql db ("INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) " ++
    "VALUES('m-job-kind','wakeup','awaiting_user','claudecode',1,'t0','t0');")
  let .ok _ ← registerContinuation store
    { id := "c-job-kind", missionId := "m-job-kind", requestId := "job-kind-1", prompt := "old",
      reason := "test", source := "mcp", triggerKind := "job", jobId := "job-kind-id", dueEpoch := t + 5000 } t "t0"
    | throw (IO.userError "job-kind initial registration")
  let .ok _ ← registerContinuation store
    { id := "c-job-kind-2", missionId := "m-job-kind", requestId := "job-kind-2", prompt := "new",
      reason := "test", source := "mcp", triggerKind := "durable_job_terminal", jobId := "job-kind-id", dueEpoch := t + 5000 } t "t1"
    | throw (IO.userError "job-kind replacement registration")
  check ((← cellOf db "SELECT trigger_kind || ':' || error FROM mission_continuations WHERE id='c-job-kind';" #[]) == "durable_job_terminal:")
    "replacing a job wake-up updates trigger_kind to durable_job_terminal"
  -- Production launcher with Stop race through `tickContinuationScheduler`.
  sql db ("INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) " ++
    "VALUES('m-real-stop','wakeup','awaiting_user',?1,1,'t0','t0');") #[s!"missing-cli-{← newUuidV4}"]
  let .ok _ ← registerContinuation store
    { id := "c-real-stop", missionId := "m-real-stop", requestId := "real-stop", prompt := "stopped before launch",
      reason := "test", source := "mcp", triggerKind := "time", dueEpoch := t + 20 } t "t0"
    | throw (IO.userError "production stop-race registration")
  let stopBeforeProdLaunch : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun mr prompt sid? claim => do
    let .ok _ ← hostedStop store mr.id "t-stop" | throw (IO.userError "production stop-race hostedStop")
    launchLocalWakeup app mr prompt sid? claim
  discard <| tickContinuationScheduler store none none none sup none root (some stopBeforeProdLaunch) (some (t + 20))
  check ((← cellOf db "SELECT status || ':' || terminal_reason FROM missions WHERE id='m-real-stop';" #[]) == "interrupted:hosted_stop" &&
    (← cellOf db "SELECT phase || ':' || error FROM mission_continuations WHERE id='c-real-stop';" #[]) == "4:wakeup_claim_fenced" &&
    (← cellOf db "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-real-stop' AND event_type='error';" #[]) == "0")
    "fenced production launch through scheduler preserves hosted_stop, retires claim fenced, and emits no spurious error"
  -- Archived (acknowledged) mission wake-ups are retired as owner_terminal, never woken.
  sql db ("INSERT INTO missions(id,title,status,backend,run_generation,created_at,updated_at) " ++
    "VALUES('m-arch-wake','wakeup','acknowledged',?1,1,'t0','t0');") #[s!"missing-cli-{← newUuidV4}"]
  sql db ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
    "VALUES('c-arch-wake','m-arch-wake',1,1,CAST(?1 AS INTEGER),'time','test','do not wake','c-arch-wake','','mcp','','',1,'t0','t0');") #[s!"{t + 20}"]
  discard <| tick (t + 20)
  check ((← cellOf db "SELECT status FROM missions WHERE id='m-arch-wake';" #[]) == "acknowledged" &&
    (← cellOf db "SELECT phase || ':' || error FROM mission_continuations WHERE id='c-arch-wake';" #[]) == "4:owner_terminal")
    "archived mission wake-ups are retired without waking or retry-spinning"

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
      let launch : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun mr _ _ _ => do
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
      let mut retryNow := due + 6002
      for _ in [0:maxWakeupLaunchTries + 2] do
        retryNow := retryNow + 1000
        tick retryNow
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
      let staleClaim ← OrbCore.QueueCont.actOnContinuation store "f-keep" "resume" "t2" 2000000000 (some ("f-keep", 3))
      check (match staleClaim with | .error "continuation_snapshot_changed" => true | _ => false)
        "a carried occurrence rejects its old scheduler generation"
      check ((← cellOf store.missionsDb "SELECT phase FROM mission_continuations WHERE id='f-keep';" #[]) == "1")
        "a stale claim must leave the carried wake-up armed"
      -- Same row, same generation and already-due deadline, different request:
      -- only request identity distinguishes the new payload from the scan.
      let .ok _ ← execParamQuery store.missionsDb
          "UPDATE missions SET run_generation=4 WHERE id='m-follow';" #[]
        | throw (IO.userError "claim mission generation")
      let replacement : OrbCore.QueueCont.ContinuationDraft := {
        id := "unused-replacement-id", missionId := "m-follow", requestId := "f-new",
        prompt := "new due prompt", reason := "test", source := "mcp",
        triggerKind := "time", dueEpoch := 1900000001 }
      let .ok replacedId ← OrbCore.QueueCont.registerContinuation store replacement 1800000000 "t2"
        | throw (IO.userError "due replacement registration")
      check (replacedId == "f-keep") "replacement must exercise same-row identity"
      let .ok replayId ← OrbCore.QueueCont.registerContinuation store replacement 1800000000 "t2"
        | throw (IO.userError "replacement registration replay")
      check (replayId == replacedId) "same-request registration replay preserves identity"
      let oldClaim ← OrbCore.QueueCont.actOnContinuation store replacedId "resume" "t3" 2000000000 (some ("f-keep", 4))
      check (match oldClaim with | .error "continuation_snapshot_changed" => true | _ => false)
        "old same-generation snapshot cannot claim new due payload"
      check ((← cellOf store.missionsDb "SELECT phase || ':' || prompt FROM mission_continuations WHERE id='f-keep';" #[]) == "1:new due prompt")
        "rejected old claim leaves replacement payload armed"
      let newClaim ← OrbCore.QueueCont.actOnContinuation store replacedId "resume" "t3" 2000000000 (some ("f-new", 4))
      check (match newClaim with | .ok (.ok "m-follow") => true | _ => false)
        "matching replacement snapshot claims normally"
      let duplicateClaim ← OrbCore.QueueCont.actOnContinuation store replacedId "resume" "t3" 2000000000 (some ("f-new", 4))
      check (match duplicateClaim with | .error _ => true | _ => false)
        "a claimed occurrence cannot be claimed twice"
      -- A throw before launch and a throw after acceptance look identical to
      -- today's Bool callback. Neither may blindly reset a claimed occurrence.
      -- Record both event orders explicitly before attempting any recovery fix.
      for accepted in #[false, true] do
        let mid := if accepted then "m-accepted-throw" else "m-presubmit-throw"
        let cid := if accepted then "c-accepted-throw" else "c-presubmit-throw"
        let .ok _ ← execParamQuery store.missionsDb
            ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
             "VALUES(?1,'wakeup','awaiting_user','claudecode','','','managed','[]',1,1,'t0','t0');") #[mid]
          | throw (IO.userError "fault mission insert failed")
        let .ok _ ← OrbCore.QueueCont.registerContinuation store
            { id := cid, missionId := mid, requestId := cid, prompt := "fault probe",
              reason := "test", source := "mcp", triggerKind := "time", dueEpoch := due + 250000 }
            due "t0"
          | throw (IO.userError "fault continuation registration")
        let attempts ← IO.mkRef (0 : Nat)
        let acceptedInputs ← IO.mkRef (#[] : Array String)
        let faultyLaunch : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun _ prompt _ _ => do
          check ((← cellOf store.missionsDb "SELECT phase FROM mission_continuations WHERE id=?1;" #[cid]) == "2")
            "fault injection must occur after durable claim"
          attempts.modify (· + 1)
          if accepted then acceptedInputs.modify (·.push prompt)
          throw (IO.userError "injected launch boundary fault")
        let tickFault := fun t => tickContinuationScheduler store none none none sup none root (some faultyLaunch) t
        let threw ← try
          discard <| tickFault (some (due + 250001))
          pure false
        catch _ => pure true
        check threw "baseline launch boundary fault must escape the scheduler pass"
        discard <| tickFault (some (due + 250100))
        check ((← attempts.get) == 1) "claimed uncertain launch must not be blindly replayed"
        check ((← acceptedInputs.get).size == (if accepted then 1 else 0))
          "pre-submit and accepted-before-error have different external effects"
        check ((← cellOf store.missionsDb "SELECT phase FROM mission_continuations WHERE id=?1;" #[cid]) == "2")
          "baseline fault leaves the claimed occurrence outside future scans"
      -- The due scan is a snapshot. While A launches, B's same-job watcher is
      -- replaced. B must not consume the replacement using the old prompt.
      for mid in #["m-snapshot-a", "m-snapshot-b", "m-stop-retry"] do
        let .ok _ ← execParamQuery store.missionsDb
            ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
             "VALUES(?1,'wakeup','awaiting_user','claudecode','','','managed','[]',1,1,'t0','t0');") #[mid]
          | throw (IO.userError "snapshot mission insert failed")
      let now := due + 300000
      let register := fun (id mid prompt kind job : String) (dueAt : UInt64) =>
        OrbCore.QueueCont.registerContinuation store
          { id := id, missionId := mid, requestId := id, prompt := prompt,
            reason := "test", source := "mcp", triggerKind := kind, jobId := job, dueEpoch := dueAt }
          (now - 100) "t0"
      let .ok _ ← register "snapshot-a" "m-snapshot-a" "first" "time" "" (now - 1)
        | throw (IO.userError "snapshot A registration")
      let .ok _ ← register "snapshot-b" "m-snapshot-b" "old" "durable_job_terminal" "job-done" (now + 86400)
        | throw (IO.userError "snapshot B registration")
      let delivered ← IO.mkRef (#[] : Array String)
      let replaceDuringLaunch : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun mr prompt _ _ => do
        if mr.id == "m-snapshot-a" then
          let .ok _ ← register "snapshot-b-new" "m-snapshot-b" "replacement" "durable_job_terminal" "job-done" (now + 86400)
            | throw (IO.userError "replace B during A launch")
        else if mr.id == "m-snapshot-b" then
          -- Observe actual local process input/output, not just a callback Bool.
          -- This verifies local delivery only, not a remote node/provider ACK.
          let receipt ← IO.Process.output { cmd := "/usr/bin/printf", args := #["%s", prompt] }
          check (receipt.exitCode == 0) "local scheduled-input process must exit successfully"
          delivered.modify (·.push receipt.stdout)
        return true
      discard <| tickContinuationScheduler store none none none sup none root (some replaceDuringLaunch) (some now)
      discard <| tickContinuationScheduler store none none none sup none root (some replaceDuringLaunch) (some (now + 1))
      check ((← delivered.get) == #["replacement"])
        "snapshot replacement must deliver only the replacement prompt exactly once"
      -- Stop wins while the admitted launch is returning a definite failure.
      -- Retry must never adopt Stop's newer generation and resurrect the wake.
      let .ok _ ← register "stop-retry" "m-stop-retry" "stop me" "time" "" now
        | throw (IO.userError "stop retry registration")
      let stoppedLaunches ← IO.mkRef (0 : Nat)
      let stopDuringLaunch : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun mr _ _ _ => do
        stoppedLaunches.modify (· + 1)
        let .ok _ ← OrbCore.QueueCont.hostedStop store mr.id "t-stop"
          | throw (IO.userError "stop during failed launch")
        return false
      discard <| tickContinuationScheduler store none none none sup none root (some stopDuringLaunch) (some now)
      discard <| tickContinuationScheduler store none none none sup none root (some stopDuringLaunch) (some (now + 120))
      check ((← stoppedLaunches.get) == 1) "Stop must fence a failed launch retry"
      check ((← cellOf store.missionsDb "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-stop-retry' AND phase=1;" #[]) == "0")
        "Stop must leave no rearmed wake-up"
      verifyProductionLocalFailure store sup root (now + 5000)
      verifyLegacyMigration store (now + 10000)
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root

end OrbCore.WakeupRestartTests
