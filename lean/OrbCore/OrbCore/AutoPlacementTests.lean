import OrbCore.McpGateway
import OrbCore.AutoPlacement

namespace OrbCore.AutoPlacementTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.MemoryAndCloud OrbCore.AutoPlacement
open OrbCore.RemoteFleetAndRelay

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"auto placement: {label}")

private def chooserTests : IO Unit := do
  let fleet : Array Candidate := #[
    { id := "ashur", activeJobs := 1 }, { id := "babylon", activeJobs := 1 },
    { id := "nippur", cordoned := true }, { id := "agent-core", reserved := true }, { id := "ur", activeJobs := 3 }]
  check (choose fleet #[] == some "ashur") "configuration order breaks a tie"
  check (choose fleet #["ashur"] == some "babylon") "an excluded node is never chosen"
  check (choose fleet #["ashur", "babylon"] == some "ur") "a busier node beats an excluded one"
  check (choose fleet #["ashur", "babylon", "ur"] == none) "cordoned and reserved nodes are never a fallback"
  check (choose #[{ id := "ashur", activeJobs := 2 }, { id := "ur" }] #[] == some "ur") "fewest active jobs wins"
  check (choose #[] #[] == none) "empty fleet"
  check (normalizeAll #[" Ashur ", "ashur", "", "UR"] == #["ashur", "ur"]) "exclusions are normalised and deduplicated"
  check (exclusionsOfTags #["remote-node:ur", "exclude-node:Ashur", "exclude-node:", "exclude-node:ashur"] == #["ashur"])
    "only exclusion tags count"
  let node (id url : String) (labels : Array String := #[]) : StaticRemoteNode := { id, baseUrl := url, tokenEnv := "T", labels }
  check (!reserved (node "ashur" "http://10.88.0.4:8080")) "a fleet node is not reserved"
  for n in #[node "agent-core" "http://10.88.0.9:1", node "x" "http://10.88.0.1:8080", node "y" "http://127.0.0.1:1",
      node "z" "http://10.88.0.7:1" #["admin-only"], node "w" "http://10.88.0.8:1" #["control-plane"]] do
    check (reserved n) s!"{n.id} is reserved"

/-- `start_mission` through the real dispatcher against a configured static fleet. -/
private def gatewayTests (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/placement-core"
    | throw (IO.userError "placement core open failed")
  try
    OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES_ENABLED" "true"
    OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES"
      "ashur=http://10.99.0.2:1|T,babylon=http://10.99.0.3:1|T,nippur=http://10.99.0.4:1|T,agent-core=http://10.99.0.5:1|T,ur=http://10.99.0.6:1|T"
    let now : UInt64 := 1000
    let fleet : ManagedFleetState := {}
    let sql (query : String) (args : Array String := #[]) : IO (Array (Array String)) := do
      match ← execParamQuery store.missionsDb query args with
      | .ok rows => pure rows
      | .error e => throw (IO.userError s!"auto placement: fixture query failed: {e}")
    discard <| sql "INSERT INTO users(id,username,password_hash,role) VALUES('alice','alice','synthetic-hash','admin');"
    for (id, parent, tags) in #[("pareto", "", "[\"exclude-node:Ashur\"]"), ("worker", "pareto", "[]"),
        ("free", "", "[]"), ("legacy", "", "[\"remote-node:auto\"]")] do
      discard <| sql "INSERT INTO missions(id,parent_mission_id,owner_user_id,project,tags) VALUES(?1,NULLIF(?2,''),'alice','p',?3);"
        #[id, parent, tags]
    discard <| sql ("CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', " ++
      "node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
      "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');")
    for (job, nodeId, state) in #[("j1", "babylon", "running"), ("j2", "ur", "running"), ("j3", "ur", "queued"),
        ("j4", "ashur", "completed"), ("j5", "babylon", "lost")] do
      discard <| sql "INSERT INTO remote_node_jobs(job_id,node_id,state) VALUES(?1,?2,?3);" #[job, nodeId, state]
    check (← setPersistedNodeCordoned store.rootDir "nippur" true) "cordon fixture"
    check ((← lineageExclusions store "worker") == #["ashur"]) "an ancestor's exclusion binds a descendant"
    check ((← lineageExclusions store "free").isEmpty && (← lineageExclusions store "").isEmpty) "no exclusion by default"
    let start (mission : String) (extra : Array (String × JVal) := #[]) : IO JVal := do
      let claims : McpSessionClaims := {
        sessionId := "placement-session", missionId := mission, role := "coordinator", expiresAt := 2000
      }
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root claims
        "start_mission" (.obj (#[("title", JVal.str "placed")] ++ extra)) now
      let .ok parsed := OrbBin.Json.parse raw | throw (IO.userError "auto placement: gateway JSON")
      return parsed
    let tagsOf (reply : JVal) : IO (Array String) := do
      let some id := ((reply.field? "result").getD .null).fieldStr? "mission_id"
        | throw (IO.userError s!"auto placement: mission not created: {renderCompact reply}")
      let rows ← sql "SELECT COALESCE(tags,'[]') FROM missions WHERE id=?1;" #[id]
      match OrbBin.Json.parse ((rows[1]?.bind (·[0]?)).getD "[]") with
      | .ok (.arr items) => return items.filterMap JVal.asStr?
      | _ => return #[]
    let errorOf (reply : JVal) : Option String × Option String :=
      let err := (reply.field? "error").getD .null
      (err.fieldStr? "code", err.fieldStr? "message")
    let missionCount : IO Nat := do return (← sql "SELECT id FROM missions;").size - 1
    -- R15: `writer:false` must be persisted as readonly at the MCP launch
    -- boundary, rather than being inferred later from a tag or prompt.
    let readonlyReply ← start "readonly-launch" #[
      ("writer", .bool false)]
    let some readonlyId := ((readonlyReply.field? "result").getD .null).fieldStr? "mission_id"
      | throw (IO.userError "R15 start_mission(writer:false) did not create a mission")
    let readonlyRows ← sql "SELECT authority_mode FROM missions WHERE id=?1;" #[readonlyId]
    check ((readonlyRows[1]?.bind (·[0]?)).getD "" == "readonly")
      "R15 writer:false launch is persisted readonly"
    let readonlyClaims : McpSessionClaims := {
      sessionId := "readonly-session", missionId := readonlyId, role := "executor", expiresAt := 2000 }
    let refusedRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root readonlyClaims
      "start_mission" (.obj #[("title", .str "forbidden child"), ("idempotency_key", .str "r15-readonly-child")]) now
    let refused := (OrbBin.Json.parse refusedRaw).toOption.getD .null
    check ((refused.field? "error" |>.bind (·.fieldStr? "code")) == some "read_only_mission")
      "R15 readonly mission refuses mutating child launch"
    -- Unconstrained: ashur is idle (its only job finished), so it is the least busy node.
    let free ← tagsOf (← start "free")
    check (free.contains "remote-node:ashur") s!"least busy node is chosen: {free}"
    check (!free.any (·.startsWith "exclude-node:")) "no exclusion is invented"
    -- The Pareto case: a worker of a lineage that excludes ashur goes elsewhere,
    -- to a concrete node, and carries the exclusion on.
    let worker ← tagsOf (← start "worker")
    check (worker.contains "remote-node:babylon" && worker.contains "exclude-node:ashur")
      s!"an excluded node is skipped and the exclusion is inherited: {worker}"
    check (!worker.any (fun t => t == "remote-node:auto" || t == "remote-node:ashur")) "the placement is concrete"
    -- Naming the excluded node, or excluding every usable node, creates nothing.
    let before ← missionCount
    let named ← start "worker" #[("remote_node_id", .str "ASHUR")]
    check ((errorOf named).1 == some "placement_excluded") "an excluded node cannot be named"
    let exhausted ← start "worker" #[("exclude_nodes", .arr #[.str "babylon", .str "ur"])]
    check (errorOf exhausted == (some "placement_failed", some "no_eligible_node"))
      "cordoned and control-plane nodes are not a fallback"
    check ((← missionCount) == before) "a refused placement creates no mission"
    -- A per-call exclusion adds to the lineage's.
    let narrowed ← tagsOf (← start "worker" #[("exclude_nodes", .arr #[.str "babylon"])])
    check (narrowed.contains "remote-node:ur" && narrowed.contains "exclude-node:ashur" &&
      narrowed.contains "exclude-node:babylon") s!"per-call exclusions add to inherited ones: {narrowed}"
    -- An explicit node outside the exclusions is honoured as given.
    let explicit ← tagsOf (← start "worker" #[("remote_node_id", .str "nippur")])
    check (explicit.contains "remote-node:nippur") "an explicit node is not second-guessed"
    -- A parent recorded as `auto` keeps its children on the node it resolves to.
    let legacy ← tagsOf (← start "legacy")
    check (legacy.contains "remote-node:ashur" && legacy.contains "fork-workspace:legacy")
      s!"children of a legacy auto parent stay with it: {legacy}"
    -- R19: play two observations of the same incident through the durable
    -- ledger, automatic placement and the actual MCP resume boundary, while
    -- ensuring a single transient blip or fresh active job poll never flags.
    discard <| sql "UPDATE remote_node_jobs SET mission_id='free' WHERE job_id='j1'"
    discard <| sql "UPDATE remote_node_jobs SET mission_id='worker' WHERE job_id='j2'"
    for n in #["ashur", "ur"] do -- healthy idle / healthy active
      observeNodeApi store n "online" "t0" (throw (IO.userError "healthy API must not require ping"))
    observeNodeApi store "babylon" "offline" "t0" (pure false)
    check (← nodeApiHangCause? store "babylon").isNone "R19: unreachable host alone is not an API hang"
    -- A single transient timeout recovered on the next heartbeat must neither cordon nor emit mission errors.
    observeNodeApi store "babylon" "offline" "t0-blip" (pure true)
    check (← nodeApiHangCause? store "babylon").isNone "R19: single transient timeout does not cordon node"
    let blipFlags ← sql "SELECT mission_id FROM mission_events WHERE json_extract(payload,'$.reason')='hung_node'"
    check (blipFlags.size == 1) "R19: single transient timeout emits no mission error event"
    -- An unreachable host (`ping = false`) clears an unconfirmed single strike so a later blip does not accumulate.
    observeNodeApi store "babylon" "offline" "t0-unreach" (pure false)
    observeNodeApi store "babylon" "offline" "t0-blip2" (pure true)
    check (← nodeApiHangCause? store "babylon").isNone "R19: unpingable observation resets unconfirmed 1-strike blip"
    observeNodeApi store "babylon" "online" "t0-recover" (pure false)
    -- Fresh active `/jobs/:id` HTTP activity suppresses false hang conviction even across two missed heartbeats.
    discard <| sql "UPDATE remote_node_jobs SET updated_at='2026-11-25T23:14:28Z' WHERE job_id='j1'"
    observeNodeApi store "babylon" "offline" "2026-11-25T23:14:29Z" (pure true)
    observeNodeApi store "babylon" "offline" "2026-11-25T23:14:30Z" (pure true)
    check (← nodeApiHangCause? store "babylon").isNone "R19: fresh active job HTTP poll proves API is responsive"
    discard <| sql "UPDATE remote_node_jobs SET updated_at='' WHERE job_id='j1'"
    -- Add a second active job on `Babylon` (mixed case) for the same mission `free` and a job on `legacy`
    -- (`remote-node:auto`) to prove single flagging and concrete job-node resolution on resume.
    discard <| sql "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state) VALUES('j1-extra','free','Babylon','queued');"
    discard <| sql "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state) VALUES('j-leg','legacy','babylon','running');"
    -- Consecutive pingable API misses without fresh job activity confirm the hang and flag each affected mission once.
    for t in #["t1", "t2", "t2b"] do observeNodeApi store "babylon" "offline" t (pure true)
    let (_, nodes) ← loadStaticRemoteNodes
    let cs ← candidates store nodes
    check (choose (cs.filter (·.id == "babylon")) #[] == none) "R19: pingable hung node excluded"
    for n in #["ashur", "ur"] do
      check (choose (cs.filter (·.id == n)) #[] == some n) "R19: healthy idle and active stay eligible"
    -- `resolveConcreteRemoteTargetNode` with `"auto"` skips hung/cordoned nodes and picks healthy `ur`.
    let autoRes ← OrbCore.RemoteDispatch.resolveConcreteRemoteTargetNode none "auto" (some (store, "worker"))
    check (autoRes.toOption == some "ur") s!"R19: auto target resolution skips excluded ashur, cordoned nippur, and hung babylon: {reprStr autoRes}"
    -- Confirmed hang survives a brief unpingable observation (e.g. reboot) until a healthy `online` heartbeat arrives.
    observeNodeApi store "babylon" "offline" "t2-reboot" (pure false)
    check (← nodeApiHangCause? store "babylon").isSome "R19: confirmed hang stays cordoned across unpingable reboot until online"
    let flags ← sql "SELECT mission_id FROM mission_events WHERE json_extract(payload,'$.reason')='hung_node' ORDER BY mission_id"
    check (flags.size == 3 && cell flags[1]! 0 == "free" && cell flags[2]! 0 == "legacy")
      s!"R19: each affected mission flagged exactly once despite 2 jobs and 3 strikes: {reprStr flags}"
    -- Legacy `remote-node:auto` mission with a job on `babylon` resolves to `babylon` and names it on resume.
    check ((← OrbCore.RemoteDispatch.resolveMissionRemoteNode? store none "legacy") == some "babylon")
      "R19: legacy auto mission with job on hung node resolves concrete job node"
    let claims : McpSessionClaims := { sessionId := "r19", missionId := "free", role := "coordinator", expiresAt := 2000 }
    let resume ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root claims "resume_mission"
      (.obj #[("mission_id", .str "free"), ("idempotency_key", .str "r19-resume")]) now
    check (resume.contains "babylon" && resume.contains "API is unresponsive") s!"R19: resume names the cause: {resume}"
    let legacyClaims : McpSessionClaims := { claims with missionId := "legacy" }
    let resumeLegacy ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root legacyClaims "resume_mission"
      (.obj #[("mission_id", .str "legacy"), ("idempotency_key", .str "r19-resume-legacy")]) now
    check (resumeLegacy.contains "babylon" && resumeLegacy.contains "API is unresponsive")
      s!"R19: legacy auto resume names the hung node: {resumeLegacy}"
    -- Finding 2: `native_owner_enrollments` nodes are excluded from `AutoPlacement.candidates`.
    discard <| sql "INSERT INTO native_owner_enrollments(node_id,owner_id,account_id,revision) VALUES('ur','alice','acct-1',1);"
    let csEnrolled ← candidates store nodes
    check (choose (csEnrolled.filter (·.id == "ur")) #[] == none) "R19: native-owner-enrolled node excluded from auto placement"
    discard <| sql "DELETE FROM native_owner_enrollments WHERE node_id='ur';"
    -- Finding 4: legacy `remote-node:auto` with concrete node only in `mission_runs.scope_unit` resolves to `babylon`.
    discard <| sql "INSERT INTO missions(id,owner_user_id,project,status,tags) VALUES('legacy-run','alice','p','interrupted','[\"remote-node:auto\"]');"
    discard <| sql "INSERT INTO mission_runs(id,mission_id,generation,execution_state,scope_unit) VALUES('run-leg-1','legacy-run',1,'terminal','remote-node:babylon');"
    check ((← OrbCore.RemoteDispatch.resolveMissionRemoteNode? store none "legacy-run") == some "babylon")
      "R19: legacy auto mission resolves concrete node from mission_runs.scope_unit"
    let legRunClaims : McpSessionClaims := { claims with missionId := "legacy-run" }
    let resumeLegRun ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root legRunClaims "resume_mission"
      (.obj #[("mission_id", .str "legacy-run"), ("idempotency_key", .str "r19-resume-legrun")]) now
    check (resumeLegRun.contains "babylon" && resumeLegRun.contains "API is unresponsive")
      s!"R19: legacy auto scope_unit resume names hung node: {resumeLegRun}"
    -- Finding 5: `interrupted` mission with an `'unreachable'` job row refuses `send_message_to_mission`
    -- (with or without `remoteSup?`), appends 0 phantom events, and does not mutate `missions.title`.
    discard <| sql "INSERT INTO missions(id,title,owner_user_id,project,status,tags) VALUES('idle-bab','Original Title','alice','p','interrupted','[\"remote-node:babylon\"]');"
    discard <| sql "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state) VALUES('j-idle-unreach','idle-bab','babylon','unreachable');"
    let dummySup ← OrbCore.RemoteDispatch.newRemoteJobSupervisor
    let idleClaims : McpSessionClaims := { claims with missionId := "idle-bab" }
    let sendMsg ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root idleClaims "send_message_to_mission"
      (.obj #[("mission_id", .str "idle-bab"), ("title", .str "Mutated Title"), ("content", .str "hello"), ("idempotency_key", .str "r19-send-hung")]) now (remoteSup? := some dummySup)
    let sendMsgNoSup ← OrbCore.McpGateway.dispatchMcpToolCall store none none none fleet root idleClaims "send_message_to_mission"
      (.obj #[("mission_id", .str "idle-bab"), ("title", .str "Mutated Title 2"), ("content", .str "hello"), ("idempotency_key", .str "r19-send-hung-nosup")]) now
    let idleEvs ← sql "SELECT event_type FROM mission_events WHERE mission_id='idle-bab'"
    let idleTitle ← sql "SELECT title FROM missions WHERE id='idle-bab'"
    check (sendMsg.contains "hung_node" && sendMsg.contains "babylon" &&
           sendMsgNoSup.contains "hung_node" && sendMsgNoSup.contains "babylon" &&
           idleEvs.size == 1 && (idleTitle[1]?.bind (·[0]?)).getD "" == "Original Title")
      s!"R19: send_message_to_mission refuses hung node cleanly with zero phantom events or title mutation: {sendMsg} / {sendMsgNoSup} evs={reprStr idleEvs} title={reprStr idleTitle}"
    -- Finding 3: `tickRemoteFollowupPump` skips missions on a hung node without claiming or flooding error events.
    discard <| sql "DELETE FROM remote_node_jobs WHERE job_id='j-idle-unreach';"
    discard <| OrbCore.QueueCont.enqueueStructuredFollowup store "core" "r19-q-msg-1" "idle-bab" "follow up while hung" "control" "2026-11-28T00:00:00Z"
    let pumpedWhileHung ← OrbCore.RemoteDispatch.tickRemoteFollowupPump store none none none dummySup root now
    let idleEvsAfterPump ← sql "SELECT event_type FROM mission_events WHERE mission_id='idle-bab'"
    check (pumpedWhileHung == 0 && idleEvsAfterPump.size == 1)
      s!"R19: tickRemoteFollowupPump must not claim or emit errors while node is hung: pumped={pumpedWhileHung} evs={reprStr idleEvsAfterPump}"
    -- Recovery/uncordoning clears the hang incident, restores placement eligibility, and preserves operator cordons.
    observeNodeApi store "babylon" "online" "t3" (pure false)
    check (← nodeApiHangCause? store "babylon").isNone "R19: healthy heartbeat clears the incident"
    let csRecovered ← candidates store nodes
    check (choose (csRecovered.filter (·.id == "babylon")) #[] == some "babylon") "R19: recovered node eligible again"
    check (choose (csRecovered.filter (·.id == "nippur")) #[] == none) "R19: independent operator cordon preserved on recovery"
    discard <| sql "DELETE FROM remote_node_jobs WHERE job_id IN ('j1-extra','j-leg');"
  finally
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
    closeCoreStore store

/-- Every branch of the one provider decision, with fixed refusals. -/
private def providerChoiceTests : IO Unit := do
  let asked ← IO.mkRef (#[] : Array String)
  let chooseWith (named? : Option String) (defaultProvider : String) (pinned : Bool)
      (refusals : Array (String × String)) : IO ManagedProviderChoice := do
    asked.set #[]
    chooseManagedProvider named? defaultProvider pinned fun candidate => do
      asked.modify (·.push candidate)
      return (refusals.find? (·.1 == candidate)).map (·.2)
  let only (provider : String) : ManagedProviderChoice := { provider := provider }
  let full := #[("leanci", "provider_at_capacity"), ("boat", "provider_disabled")]
  -- Named: used as given, nothing is even asked.
  let named ← chooseWith (some "leanci") "leanci" false full
  check (named == only "leanci" && (← asked.get).isEmpty) "a named provider is never replaced or probed"
  let namedOther ← chooseWith (some "colab") "leanci" false #[("colab", "provider_at_capacity")]
  check (namedOther == only "colab" && (← asked.get).isEmpty) "a named non-default provider is used as given"
  -- Default can take it: the fallback is not consulted.
  let onDefault ← chooseWith none "leanci" false #[("boat", "provider_disabled")]
  check (onDefault == only "leanci" && (← asked.get) == #["leanci"]) "the default is used when it can take the request"
  -- Default cannot, fallback can: every refusal reason moves the request and is recorded.
  for reason in #["default_provider_at_capacity", "provider_at_capacity", "managed_provider_availability_unavailable", "provider_disabled",
      "provider_disabled_for_user", "provider_invalid_size", "managed_provider_unavailable"] do
    let moved ← chooseWith none "leanci" false #[("leanci", reason)]
    check (moved == ({ provider := "boat", fallbackFrom := "leanci", fallbackReason := reason } : ManagedProviderChoice) &&
      (← asked.get) == #["leanci", "boat"]) s!"the default's refusal {reason} falls back to boat"
  -- Neither can: the default stays, so the caller sees the default's own error.
  let neither ← chooseWith none "leanci" false full
  check (neither == only "leanci" && (← asked.get) == #["leanci", "boat"]) "no fallback when boat cannot take it either"
  -- Pinned (snapshot, fork): never moved, never probed.
  let pinned ← chooseWith none "leanci" true #[("leanci", "provider_at_capacity")]
  check (pinned == only "leanci" && (← asked.get).isEmpty) "a pinned request stays on the default"
  -- Default boat: there is nothing to fall back to.
  let boat ← chooseWith none "boat" false #[("boat", "provider_at_capacity")]
  check (boat == only "boat" && (← asked.get).isEmpty) "a boat default has no fallback"
  -- The result annotation exists only for a fallback.
  let moved : ManagedProviderChoice := { provider := "boat", fallbackFrom := "leanci", fallbackReason := "provider_at_capacity" }
  check (renderCompact (moved.annotate (.obj #[("id", .str "m")])) ==
      "{\"id\":\"m\",\"provider_fallback\":{\"from\":\"leanci\",\"to\":\"boat\",\"reason\":\"provider_at_capacity\"}}" &&
    renderCompact (onDefault.annotate (.obj #[("id", .str "m")])) == "{\"id\":\"m\"}")
    "provider_fallback names from, to and reason, and is absent otherwise"
  -- Zero-cost admission: an exhausted or lowered cap never refuses a free machine, a paid one still is.
  let exhausted : ManagedFleetState := { enabled := true, dailyCapCents := 100, spentTodayCents := 100 }
  let lowered : ManagedFleetState := { enabled := true, dailyCapCents := 50, spentTodayCents := 100 }
  check (admitManagedSpawn exhausted 0 && admitManagedSpawn lowered 0 && !admitManagedSpawn exhausted 1 &&
    !admitManagedSpawn { exhausted with enabled := false } 0 &&
    !admitManagedSpawn { exhausted with maxConcurrent := 0 } 0 && !admitManagedSpawn exhausted 0 721)
    "a zero-cost machine passes the daily cap but not the fleet switch, concurrency or TTL"
  check (admitManagedSpawnMultiUser exhausted 0 500 (some 100) == 0 && admitManagedSpawnMultiUser lowered 0 0 none == 0 &&
    admitManagedSpawnMultiUser exhausted 1 0 none == 1 &&
    admitManagedSpawnMultiUser { exhausted with spentTodayCents := 0 } 1 100 (some 100) == 2)
    "a zero-cost machine passes the global and the user spend cap; a paid one is still capped"

/-- Who gets which admission limits. -/
private def userAdmissionTests : IO Unit := do
  let shape (a : Option ManagedUserAdmission) := a.map fun x => (x.capCents, x.spendCapped, x.maxMachines?, x.inferenceCents, x.computeCents)
  check (shape (managedUserAdmissionOf "member" none 3 4 2) == some (0, false, some 2, 3, 4))
    "a member without a spend cap still has the machine limit"
  check (shape (managedUserAdmissionOf "member" (some 500) 3 4 2) == some (500, true, some 2, 3, 4))
    "a capped member has both limits"
  check (shape (managedUserAdmissionOf "admin" (some 500) 3 4 2) == some (500, true, none, 3, 4) &&
    (managedUserAdmissionOf "admin" none 3 4 2).isNone && (managedUserAdmissionOf "" none 0 0 2).isNone)
    "an admin and the single-tenant owner have no machine limit"

def run (root : String) : IO Unit := do
  userAdmissionTests
  -- The instance default provider applies only when the request names none.
  check (defaultManagedProviderOf none == "leanci" && defaultManagedProviderOf (some "lean.ci") == "leanci" &&
    defaultManagedProviderOf (some " LeanCI ") == "leanci" && defaultManagedProviderOf (some "boat") == "boat" &&
    defaultManagedProviderOf (some "nope") == "leanci")
    "default managed provider: unset or unknown keeps leanci, lean.ci is canonicalized"
  check ((parseAutoManagedTarget "auto-managed").toOption == some (none, none) &&
    (parseAutoManagedTarget "auto-managed:large").toOption == some (none, some "large") &&
    (parseAutoManagedTarget " Auto-Managed:Lean.CI ").toOption == some (some "leanci", none) &&
    (parseAutoManagedTarget "auto-managed:boat:large").toOption == some (some "boat", some "large") &&
    (parseAutoManagedTarget "auto-managed:").toOption.isNone &&
    (parseAutoManagedTarget "auto-managed:nope:large").toOption.isNone &&
    (parseAutoManagedTarget "auto-managed:boat:large:x").toOption.isNone)
    "auto-managed keeps what the caller named: provider and size are optional"
  providerChoiceTests
  chooserTests
  gatewayTests root

end OrbCore.AutoPlacementTests
