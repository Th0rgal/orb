import OrbCore.Control
import OrbCore.Managed
import OrbCore.Store

namespace OrbCore.R18LivenessTests

open LeanSys.Posix LeanSys.Http LeanSys.WebSocket LeanSys.Auth
open OrbBin.Json OrbBin.PosixExt OrbBin.ClaudeControl
open OrbCore.Store OrbCore.Managed OrbCore.Control OrbCore.QueueCont
open OrbCore.RemoteFleetAndRelay OrbCore.RemoteDispatch OrbCore.TelemetryAndVoice OrbCore.LegacyHydrate
open OrbCore.R7Core OrbCore.MemoryAndCloud OrbCore.Proxy

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

private def queryCell (db : SqliteDb) (sql : String) (params : Array String := #[]) : IO String := do
  let rows ← require (← execParamQuery db sql params)
  pure (if rows.size > 1 then (rows[1]![0]?).getD "" else "")

/-- Bind an ephemeral localhost TCP listener and return `(fd, port)`. -/
private def bindLoopbackEphemeral : IO (Fd × UInt16) := do
  let .ok (fd, port) ← tcpListen "127.0.0.1" 0 32
    | throw (IO.userError "r18 liveness: tcpListen failed")
  return (fd, port)

/-- Read bytes from `fd` until `pred` matches or `deadlineMs` passes. -/
private def readUntilMs (fd : Fd) (timeoutMs : Nat) (pred : ByteArray → Bool) : IO ByteArray := do
  let deadline := (← IO.monoMsNow) + timeoutMs
  let mut acc := ByteArray.empty
  while (← IO.monoMsNow) < deadline && !pred acc do
    match ← pollReadable fd 50 with
    | .error _ => pure ()
    | .ok () =>
      let chunk ← readStreamChunk fd 16384
      if chunk.isEmpty then break
      acc := acc ++ chunk
  return acc

/-- Find `\r\n\r\n` separator offset in a raw HTTP response buffer. -/
private def findHeaderEnd (buf : ByteArray) : Option Nat := Id.run do
  if buf.size < 4 then return none
  for i in [0 : buf.size - 3] do
    if buf[i]! == 13 && buf[i+1]! == 10 && buf[i+2]! == 13 && buf[i+3]! == 10 then
      return some (i + 4)
  return none

/-- Encode a masked RFC 6455 client frame (`maskKey = 0x12345678`). -/
private def encodeClientWsText (payload : ByteArray) : ByteArray :=
  let mask : ByteArray := ByteArray.mk #[0x12, 0x34, 0x56, 0x78]
  (encodeFrame? { fin := true, opcode := .text, payload := payload } (some mask)).getD ByteArray.empty

private def encodeClientWsClose : ByteArray :=
  let mask : ByteArray := ByteArray.mk #[0x12, 0x34, 0x56, 0x78]
  (encodeFrame? { fin := true, opcode := .close, payload := ByteArray.empty } (some mask)).getD ByteArray.empty

private def mkTestApp (store : CoreStore) (root : String)
    (mc? : Option ManagedComputeStore := none)
    (bHub? : Option BroadcastHub := none)
    (rHub? : Option RelayHub := none)
    (remSup? : Option RemoteJobSupervisor := none)
    (warmMgr? : Option WarmHarnessManager := none)
    (telem? : Option TelemetrySink := none) : IO (CoreAppState × String × String) := do
  let nowSec ← coreEpochSec
  let jwtSec := "r18-liveness-jwt-secret-0123456789abcdef"
  let cfg : CoreConfig := {
    host := "127.0.0.1"
    port := 13000
    workingDir := root
    devMode := false
    dashboardPassword := "strong-r18-pass-1234"
    jwtSecret := jwtSec
  }
  let .ok adminId ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] (formatEpochIso8601Utc nowSec)
    | throw (IO.userError "r18 liveness: bootstrap admin failed")
  let jwt := issueHs256Jwt jwtSec adminId "admin" nowSec (nowSec + 86400) "admin"
  let app : CoreAppState := {
    cfg := cfg
    store := store
    searchIdx? := none
    managedRef := (← IO.mkRef ({ enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 20 } : ManagedFleetState))
    chainsRef := (← IO.mkRef (#[] : Array RoutingChain))
    proxyCooldownsRef := (← IO.mkRef (#[] : Array AccountCooldown))
    seqRef := (← IO.mkRef (0 : UInt64))
    managedStore? := mc?
    broadcastHub? := bHub?
    relayHub? := rHub?
    remoteSup? := remSup?
    warmMgr? := warmMgr?
    telemetrySink? := telem?
    bootstrapAdminId := adminId
  }
  return (app, adminId, jwt)

private def sendRest (app : CoreAppState) (jwt method path body : String) (nowSec? : Option UInt64 := none) : IO (Nat × String) := do
  let nowSec ← match nowSec? with | some t => pure t | none => coreEpochSec
  let b := body.toUTF8
  let raw := (s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n" ++
    s!"Content-Type: application/json\r\nContent-Length: {b.size}\r\n\r\n").toUTF8 ++ b
  let .ok req := parseRequest raw none | throw (IO.userError s!"r18 liveness: REST parse failed for {path}")
  match ← dispatchCoreRequest app req nowSec with
  | .error _ => return (101, "")
  | .ok resp => return (resp.status, (String.fromUTF8? resp.body).getD "")

/-- Restart must mark only genuinely ownerless active turns (including stale
    local `mission_runs`), emit one durable receipt, leave live runs and
    client-owned turns alone, and the periodic backstop must reap runs whose
    mission ended or archived. (`RUN-01`, `RUN-03`) -/
def recoveryAndOrphanReaping (root : String) : IO Unit := do
  let .ok store ← openCoreStore root
    | throw (IO.userError "r18 liveness: open core store")
  try
    missionSql store.missionsDb "m-lost" "active" "managed" 1
    missionSql store.missionsDb "m-lost-local" "active" "local" 1
    missionSql store.missionsDb "m-live" "active" "managed" 1
    missionSql store.missionsDb "m-client" "active" "client" 1
    missionSql store.missionsDb "m-done" "completed" "managed" 1
    missionSql store.missionsDb "m-arch" "acknowledged" "managed" 1
    addRun store.missionsDb "r-live" "m-live" "1" "running"
    addRun store.missionsDb "r-done" "m-done" "1" "running"
    addRun store.missionsDb "r-arch" "m-arch" "1" "running"
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,owner_actor_id,scope_unit,updated_at) " ++
       "VALUES('r-local-dead','m-lost-local',1,'running','','','local-core','local-proc:99999','2026-01-01T00:00:00Z');") #[])
    discard <| require (← mintMissionProxyToken store "m-lost-local" "" 1899999999)
    let archive ← setMissionStatusFromClient store "m-lost" "acknowledged" "2026-01-01T00:00:01Z"
    match archive with
    | .error e => check (e == "mission_running") "archive refuses an activated mission before its run is recorded"
    | .ok _ => throw (IO.userError "archive overwrote a live mission before run insertion")
    let lost ← interruptTurnsLostToRestart store.missionsDb
    check (lost == 2) s!"restart marks ownerless + dead-local active missions (got {lost})"
    let localTokLive ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_proxy_tokens WHERE mission_id='m-lost-local' AND revoked=0;"
    check (localTokLive == 0) s!"restart revokes mission_proxy_tokens for interrupted local turn (live={localTokLive})"
    let receipts ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-lost' AND event_type='recovery_receipt';"
    check (receipts == 1) "restart writes one recovery receipt for the lost turn"
    let localReceipts ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-lost-local' AND event_type='recovery_receipt';"
    check (localReceipts == 1) "restart writes one recovery receipt for dead local run"
    let localRunClosed ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_runs WHERE id='r-local-dead' AND execution_state='terminal' AND terminal_reason='core_restarted';"
    check (localRunClosed == 1) "restart closes dead local mission_runs atomically"
    let lostStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-lost' AND status='interrupted' AND terminal_reason='core_restarted';"
    check (lostStatus == 1) "lost mission is interrupted with core_restarted"
    let liveStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-live' AND status='active';"
    check (liveStatus == 1) "mission with a durable live run is not interrupted"
    let clientStatus ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-client' AND status='active';"
    check (clientStatus == 1) "client-owned turn is not interrupted by Core restart"
    let reaped ← reapOrphanedMissionRuns store.missionsDb "2026-01-01T00:01:00Z"
    check (reaped == 2) s!"periodic backstop reaps runs of completed and acknowledged missions (got {reaped})"
    let doneRun ← count store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE id='r-done' AND execution_state='terminal' AND terminal_reason='orphaned_scope';"
    check (doneRun == 1) "orphaned run is terminal with orphaned_scope"
    let archRun ← count store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE id='r-arch' AND execution_state='terminal' AND terminal_reason='orphaned_scope';"
    check (archRun == 1) "acknowledged mission run is reaped with orphaned_scope"
    let liveRun ← count store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE id='r-live' AND execution_state='running';"
    check (liveRun == 1) "run of a live mission is untouched"
    -- Archive cascade: archiving a parent cascades to stopped descendants and refuses if any descendant is live.
    missionSql store.missionsDb "p-arch" "completed" "managed" 1
    missionSql store.missionsDb "c-done" "failed" "managed" 1
    missionSql store.missionsDb "gc-done" "completed" "managed" 1
    missionSql store.missionsDb "c-live" "active" "managed" 1
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET parent_mission_id='p-arch' WHERE id IN ('c-done','c-live');" #[])
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET parent_mission_id='c-done' WHERE id='gc-done';" #[])
    match ← setMissionStatusFromClientCascade store "p-arch" "acknowledged" "2026-01-01T00:02:00Z" with
    | .error e => check (e == "mission_running") "archive cascade refuses parent while any descendant is live"
    | .ok _ => throw (IO.userError "archive cascade overwrote a live descendant")
    let pStillDone ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='p-arch' AND status='completed';"
    check (pStillDone == 1) "parent status stays unchanged when archive cascade is refused"
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET status='completed' WHERE id='c-live';" #[])
    match ← setMissionStatusFromClientCascade store "p-arch" "acknowledged" "2026-01-01T00:02:01Z" with
    | .error e => throw (IO.userError s!"archive cascade failed after children stopped: {e}")
    | .ok changed =>
      check (changed.size == 4) s!"archive cascade returns parent + all stopped descendants (got {changed.size})"
    let allArch ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE id IN ('p-arch','c-done','gc-done','c-live') AND status='acknowledged';"
    check (allArch == 4) s!"archive cascade updates parent + all descendants to acknowledged (got {allArch})"
  finally closeCoreStore store

/-- `FLT-08`: Cumulative multi-child ancestor dollar pools, carving validation,
    `$0` budgets (with and without `coreDb?`), daily rollover, reservation refund,
    and lineage-aware budget JSON rendering. -/
def lineageMissionBudget (root : String) : IO Unit := do
  let .ok core ← openCoreStore root
    | throw (IO.userError "r18 liveness: open core store")
  try
    missionSql core.missionsDb "parent" "active" "managed" 1
    missionSql core.missionsDb "child" "active" "managed" 1
    missionSql core.missionsDb "child-b" "active" "managed" 1
    missionSql core.missionsDb "child-carve" "active" "managed" 1
    missionSql core.missionsDb "grandchild-carve" "active" "managed" 1
    missionSql core.missionsDb "zero-m" "active" "managed" 1
    missionSql core.missionsDb "daily-m" "active" "managed" 1
    discard <| require (← execParamQuery core.missionsDb
      "UPDATE missions SET parent_mission_id='parent' WHERE id IN ('child','child-b','child-carve');" #[])
    discard <| require (← execParamQuery core.missionsDb
      "UPDATE missions SET parent_mission_id='child-carve' WHERE id='grandchild-carve';" #[])
    let .ok mc ← openManagedComputeStore s!"{root}/managed.db" (some core.missionsDb)
      | throw (IO.userError "r18 liveness: open managed store")
    try
      -- 1. Single over-budget child blocked naming ancestor pool
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "parent", budgetDeciMilliUsd? := some 100 })
      discard <| require (← saveManagedFleetConfig mc true true 1000 0 10)
      let fleet : ManagedFleetState :=
        { enabled := true, boatEnabled := true, dailyCapCents := 1000, spentTodayCents := 0, maxConcurrent := 10 }
      let machine : ManagedMachine :=
        { id := "child-vm", sandboxName := "orb-managed-child-vm", size := "small",
          ownerMission := "child", ttlMinutes := 60, spentCents := 2 }
      match ← provisionManagedMachine mc fleet machine 1700000000 with
      | .ok _ => throw (IO.userError "r18 liveness: over-budget child admission succeeded")
      | .error e =>
        check (e == "mission_budget_exceeded:parent")
          s!"child admission names the exhausted ancestor pool (got {e})"

      -- 2. Cumulative multi-child spend: parent pool = $0.05 (500 dm), child spends $0.03 (300 dm), child-b trying $0.03 fails
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "parent", budgetDeciMilliUsd? := some 500 })
      let vmA : ManagedMachine :=
        { id := "vm-a", sandboxName := "orb-managed-vm-a", size := "small",
          ownerMission := "child", ttlMinutes := 60, spentCents := 3 }
      discard <| require (← provisionManagedMachine mc fleet vmA 1700000001)
      let vmB : ManagedMachine :=
        { id := "vm-b", sandboxName := "orb-managed-vm-b", size := "small",
          ownerMission := "child-b", ttlMinutes := 60, spentCents := 3 }
      match ← provisionManagedMachine mc fleet vmB 1700000002 with
      | .ok _ => throw (IO.userError "r18 liveness: cumulative second child exceeded parent pool")
      | .error e => check (e == "mission_budget_exceeded:parent") s!"second child blocked by cumulative parent pool (got {e})"

      -- 3. Carving validation: carving $0.04 (400 dm) when only $0.02 (200 dm) remains fails
      match ← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "child-carve", budgetDeciMilliUsd? := some 400 } "" 1700000003 with
      | .ok () => throw (IO.userError "r18 liveness: over-carved child budget succeeded")
      | .error e => check (e.startsWith "mission_budget_carve_exceeds_parent:parent") s!"over-carving rejected (got {e})"
      -- Atomic carve of $0.02 (200 dm) succeeds and leaves parent 0 available
      discard <| require (← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "child-carve", budgetDeciMilliUsd? := some 200 } "" 1700000003)

      -- 3b. Post-spend child budget re-save / reduction must NOT double-count self-spend,
      -- and must enforce the floor of own spend + carved grandchildren (`FLT-08`).
      let vmCarve : ManagedMachine :=
        { id := "vm-carve", sandboxName := "orb-managed-vm-carve", size := "small",
          ownerMission := "child-carve", ttlMinutes := 60, spentCents := 1 }
      discard <| require (← provisionManagedMachine mc fleet vmCarve 1700000003)
      -- Re-saving child-carve at $0.02 after $0.01 spend must succeed (no self-spend double counting)
      discard <| require (← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "child-carve", budgetDeciMilliUsd? := some 200 } "" 1700000003)
      -- Lowering child-carve below its $0.01 spend ($0.005 = 50 dm) must fail with floor error
      match ← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "child-carve", budgetDeciMilliUsd? := some 50 } "" 1700000003 with
      | .ok () => throw (IO.userError "r18 liveness: lowering budget below own spend succeeded")
      | .error e => check (e.startsWith "mission_budget_below_committed:child-carve") s!"floor rejected (got {e})"
      -- Grandchild carves the remaining $0.01 (100 dm) from child-carve
      discard <| require (← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "grandchild-carve", budgetDeciMilliUsd? := some 100 } "" 1700000003)
      -- Lowering child-carve below own spend ($0.01) + grandchild carve ($0.01) = $0.02 fails
      match ← saveMissionBudgetConfigWithCarveCheck mc {
        missionId := "child-carve", budgetDeciMilliUsd? := some 150 } "" 1700000003 with
      | .ok () => throw (IO.userError "r18 liveness: lowering budget below grandchild carve succeeded")
      | .error e => check (e.startsWith "mission_budget_below_committed:child-carve") s!"grandchild floor rejected (got {e})"

      -- 4. Lineage-aware budget JSON rendering + MCP `get_budget` (`mode: "inherited"`, real `carved_usd`, real `available_usd`)
      let childCfg ← getMissionBudgetConfig mc "child"
      let childJson ← renderMissionBudgetJsonWithStore mc fleet childCfg "" 1700000004
      check (childJson.contains "\"mode\":\"inherited\"") s!"uncarved child renders mode=inherited: {childJson}"
      check (childJson.contains "\"pool_id\":\"parent\"") s!"child points to parent pool: {childJson}"
      let parentCfg ← getMissionBudgetConfig mc "parent"
      let parentJson ← renderMissionBudgetJsonWithStore mc fleet parentCfg "" 1700000004
      check (parentJson.contains "\"carved_usd\":0.02") s!"parent renders real carved_usd=0.02: {parentJson}"
      check (parentJson.contains "\"available_usd\":0.0") s!"parent renders available_usd=0.0: {parentJson}"
      let mcpOp : McpSessionClaims := {
        sessionId := "00000000-0000-4000-8000-000000000000", missionId := "", role := "operator", project := "", expiresAt := 1700009999
      }
      let mcpChildBud ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root mcpOp
        "get_budget" (.obj #[("mission_id", .str "child")]) 1700000004 none none "" true
      check (mcpChildBud.contains "\"mode\":\"inherited\"" && mcpChildBud.contains "\"pool_id\":\"parent\"")
        s!"FLT-08 MCP get_budget must use lineage-aware store renderer (got {mcpChildBud})"
      let mcpParentBud ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root mcpOp
        "get_budget" (.obj #[("mission_id", .str "parent")]) 1700000004 none none "" true
      check (mcpParentBud.contains "\"carved_usd\":0.02")
        s!"FLT-08 MCP get_budget parent must report real carved_usd=0.02 (got {mcpParentBud})"

      -- 4b. Multi-user cross-caller budget access must enforce target mission's owner_user_id lineage
      -- (shared participant GET, legacy-unscoped PUT, and MCP operator get_budget all see/enforce
      --  `mem-parent`'s pool owned by `u-mem-bud` rather than caller's userId!)
      let (budApp, admUid, admJwt) ← mkTestApp core root (some mc)
      let nowAuthBud ← coreEpochSec
      discard <| require (← execParamQuery core.missionsDb
        "INSERT OR REPLACE INTO users(id,username,role,password_hash,session_epoch,disabled,created_at,updated_at) VALUES('u-mem-bud','membud','member','x',1,0,?1,?1);"
        #[s!"{nowAuthBud}"])
      missionSql core.missionsDb "mem-parent" "active" "managed" 1
      missionSql core.missionsDb "mem-child" "active" "managed" 1
      discard <| require (← execParamQuery core.missionsDb
        "UPDATE missions SET owner_user_id='u-mem-bud' WHERE id='mem-parent';" #[])
      discard <| require (← execParamQuery core.missionsDb
        "UPDATE missions SET owner_user_id='u-mem-bud', parent_mission_id='mem-parent' WHERE id='mem-child';" #[])
      discard <| require (← execParamQuery core.missionsDb
        "INSERT OR REPLACE INTO mission_shares(mission_id,user_id,role,created_at) VALUES('mem-child',?1,'participant',?2);"
        #[admUid, s!"{nowAuthBud}"])
      discard <| require (← saveMissionBudgetConfig mc { missionId := "mem-parent", budgetDeciMilliUsd? := some 1000 })
      -- Shared participant (caller.userId = admUid != u-mem-bud) reading member's child sees inherited parent pool
      let (admGetSt, admGetBody) ← sendRest budApp admJwt "GET" "/api/control/missions/mem-child/budget" "" (some nowAuthBud)
      check (admGetSt == 200 && admGetBody.contains "\"mode\":\"inherited\"" && admGetBody.contains "\"pool_id\":\"mem-parent\"")
        s!"FLT-08 shared-caller GET member child budget must see inherited pool (st={admGetSt} body={admGetBody})"
      -- Member owner trying to over-carve child above parent's $0.10 cap gets 409
      let memJwt := issueHs256Jwt budApp.cfg.jwtSecret "u-mem-bud" "membud" nowAuthBud (nowAuthBud + 86400) "member"
      let (memOverSt, memOverBody) ← sendRest budApp memJwt "PUT" "/api/control/missions/mem-child/budget"
        "{\"budget_usd\":0.5}" (some nowAuthBud)
      check (memOverSt == 409 && memOverBody.contains "mission_budget_carve_exceeds_parent:mem-parent")
        s!"FLT-08 member over-carve on child must be rejected 409 (st={memOverSt} body={memOverBody})"
      -- Shared participant trying to PUT budget on member's child is rejected 403 owner_required
      let (admPutSt, admPutBody) ← sendRest budApp admJwt "PUT" "/api/control/missions/mem-child/budget"
        "{\"budget_usd\":0.5}" (some nowAuthBud)
      check (admPutSt == 403 && admPutBody.contains "owner_required")
        s!"FLT-08 shared participant PUT must be rejected 403 owner_required (st={admPutSt} body={admPutBody})"
      -- MCP get_budget by operator (callerUserId = "") on member-owned child uses target mission owner_user_id
      let mcpMemChild ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root mcpOp
        "get_budget" (.obj #[("mission_id", .str "mem-child")]) nowAuthBud none none "" true
      check (mcpMemChild.contains "\"mode\":\"inherited\"" && mcpMemChild.contains "\"pool_id\":\"mem-parent\"")
        s!"FLT-08 MCP get_budget on member child must see inherited pool (got {mcpMemChild})"

      -- 5. Refund releases reservation cleanly
      discard <| require (← refundManagedCostReservation mc "create:vm-a")
      discard <| require (← provisionManagedMachine mc fleet vmB 1700000005)

      -- 6. Direct $0 budget blocks spawn even without `coreDb?`
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "zero-m", budgetDeciMilliUsd? := some 0 })
      let vmZero : ManagedMachine :=
        { id := "vm-zero", sandboxName := "orb-managed-vm-zero", size := "small",
          ownerMission := "zero-m", ttlMinutes := 60, spentCents := 1 }
      match ← provisionManagedMachine { mc with coreDb? := none, missionsDb? := none } fleet vmZero 1700000006 with
      | .ok _ => throw (IO.userError "r18 liveness: $0 direct budget admitted spawn")
      | .error e => check (e == "mission_budget_exceeded:zero-m") s!"$0 direct budget blocked (got {e})"

      -- 7. Daily reset window rolls over on day 2
      discard <| require (← saveMissionBudgetConfig mc {
        missionId := "daily-m", budgetDeciMilliUsd? := some 200, resetPeriod := "daily" })
      let vmD1 : ManagedMachine :=
        { id := "vm-d1", sandboxName := "orb-managed-vm-d1", size := "small",
          ownerMission := "daily-m", ttlMinutes := 60, spentCents := 2 }
      discard <| require (← provisionManagedMachine mc fleet vmD1 1700000000)
      let vmD1b : ManagedMachine :=
        { id := "vm-d1b", sandboxName := "orb-managed-vm-d1b", size := "small",
          ownerMission := "daily-m", ttlMinutes := 60, spentCents := 1 }
      match ← provisionManagedMachine mc fleet vmD1b 1700000100 with
      | .ok _ => throw (IO.userError "r18 liveness: daily budget admitted second day-1 spawn")
      | .error e => check (e == "mission_budget_exceeded:daily-m") s!"daily budget blocked same-day (got {e})"
      discard <| require (← provisionManagedMachine mc fleet vmD1b (1700000000 + 86400))
    finally closeManagedComputeStore mc
  finally closeCoreStore core

/-- `FLT-05` + `FLT-06` + `FLT-07` + `RUN-10`:
    Uncertain remote submission preservation & reconciliation, partitioned durable cancel
    and poller recovery, stale-poller generation fencing, and idle-owner follow-up pump
    with rollback on definite rejection. -/
def testRemoteFaultsAndFollowupPump (root : String) : IO Unit := do
  let workDir := s!"{root}/remote-faults"
  IO.FS.createDirAll workDir
  let (listenFd, nodePort) ← bindLoopbackEphemeral
  let stopRef ← IO.mkRef false
  let postModeRef ← IO.mkRef "503"          -- "503" | "400" | "200"
  let pollModeRef ← IO.mkRef "running"      -- "503" | "running" | "succeeded"
  let cancelModeRef ← IO.mkRef "503"        -- "503" | "200"
  let staleDelayMsRef ← IO.mkRef (0 : Nat)
  let postCountRef ← IO.mkRef (0 : Nat)
  let cancelCountRef ← IO.mkRef (0 : Nat)
  let knownJobsRef ← IO.mkRef (#[] : Array String)

  let mockTask ← IO.asTask (prio := .dedicated) do
    while !(← stopRef.get) do
      match ← tcpAcceptPoll listenFd 40 with
      | .error _ => pure ()
      | .ok cfd =>
        match ← readHttpRequestFromFd cfd none 2000 with
        | .error _ => discard <| closeFd cfd
        | .ok req =>
          let (stLine, body) ←
            if req.method == "POST" && req.path == "/jobs" then do
              let _ ← postCountRef.modifyGet fun c => (c + 1, c + 1)
              let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
              let jid := (jv.fieldStr? "job_id").getD "job-r18-default"
              let mode ← postModeRef.get
              if mode == "503" then
                -- Simulate node accepted job internally then reply was lost / 503
                knownJobsRef.modify fun xs => if xs.contains jid then xs else xs.push jid
                pure ("503 Service Unavailable", "{\"error\":\"gateway_timeout\"}")
              else if mode == "400" then
                pure ("400 Bad Request", "{\"error\":\"invalid_payload\"}")
              else
                knownJobsRef.modify fun xs => if xs.contains jid then xs else xs.push jid
                pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"running\"}")
            else if req.method == "POST" && req.path.startsWith "/jobs/" && req.path.endsWith "/cancel" then do
              let p0 := (req.path.drop 6).toString
              let jid := (p0.splitOn "/cancel")[0]?.getD ""
              let cm ← cancelModeRef.get
              if cm == "503" then
                pure ("503 Service Unavailable", "{\"error\":\"partitioned\"}")
              else
                let _ ← cancelCountRef.modifyGet fun c => (c + 1, c + 1)
                pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"cancelled\"}")
            else if req.method == "GET" && req.path.startsWith "/jobs/" && (req.path.splitOn "/log").length > 1 then do
              let p0 := (req.path.drop 6).toString
              let jid := (p0.splitOn "/log")[0]?.getD ""
              if jid == "job-flt07-old" then
                let d ← staleDelayMsRef.get
                if d > 0 then IO.sleep d.toUInt32
                let ndjson := "{\"type\":\"system\",\"session_id\":\"ses-stale\"}\n{\"type\":\"result\",\"result\":\"STALE_OUTPUT_DO_NOT_APPLY\"}\n"
                pure ("200 OK", renderCompact (.obj #[
                  ("job_id", .str jid), ("offset", .nat 0), ("next_offset", .nat ndjson.utf8ByteSize),
                  ("log_len", .nat ndjson.utf8ByteSize), ("data", .str ndjson), ("state", .str "succeeded")
                ]))
              else
                let pm ← pollModeRef.get
                if pm == "503" then
                  pure ("503 Service Unavailable", "{\"error\":\"partitioned\"}")
                else if pm == "succeeded" then
                  let ndjson := "{\"type\":\"result\",\"result\":\"R18_REMOTE_OK\"}\n"
                  pure ("200 OK", renderCompact (.obj #[
                    ("job_id", .str jid), ("offset", .nat 0), ("next_offset", .nat ndjson.utf8ByteSize),
                    ("log_len", .nat ndjson.utf8ByteSize), ("data", .str ndjson), ("state", .str "succeeded")
                  ]))
                else
                  pure ("200 OK", renderCompact (.obj #[
                    ("job_id", .str jid), ("offset", .nat 0), ("next_offset", .nat 0),
                    ("log_len", .nat 0), ("data", .str ""), ("state", .str "running")
                  ]))
            else if req.method == "GET" && req.path.startsWith "/jobs/" then do
              let jid := ((req.path.drop 6).toString.splitOn "?")[0]?.getD ""
              let pm ← pollModeRef.get
              if jid == "job-flt07-old" then
                pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"succeeded\",\"exit_code\":0}")
              else if pm == "503" then
                pure ("503 Service Unavailable", "{\"error\":\"partitioned\"}")
              else
                let known ← knownJobsRef.get
                if known.contains jid then
                  pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":{jsonEscape pm},\"exit_code\":0}")
                else
                  pure ("404 Not Found", "{\"error\":\"job not found\"}")
            else
              pure ("404 Not Found", "{\"error\":\"not_found\"}")
          let b := body.toUTF8
          let wire := (s!"HTTP/1.1 {stLine}\r\nContent-Type: application/json\r\nContent-Length: {b.size}\r\nConnection: close\r\n\r\n").toUTF8 ++ b
          discard <| writeAll cfd wire false
          discard <| closeFd cfd
    discard <| closeFd listenFd

  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES" s!"mockr18=http://127.0.0.1:{nodePort}|SANDBOXED_REMOTE_NODE_MOCKR18_TOKEN"
  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODE_MOCKR18_TOKEN" "r18-mock-secret"
  OrbBin.PosixExt.setenvVar "SANDBOXED_PUBLIC_URL" "http://127.0.0.1:13000"

  let .ok store ← openCoreStore s!"{workDir}/store" 0 "prod"
    | throw (IO.userError "r18 liveness: open store for remote faults")
  try
    let .ok () ← ensureQueueContSchema store
      | throw (IO.userError "r18 liveness: ensureQueueContSchema")
    let bHub ← newBroadcastHub
    let rHub ← newRelayHub 0
    let remSup ← newRemoteJobSupervisor "r18-liveness-jwt-secret-0123456789abcdef" false
    let (app, adminId, jwt) ← mkTestApp store workDir none (some bHub) (some rHub) (some remSup)
    let nowSec ← coreEpochSec

    -- === FLT-05: Ordinary POST /api/control/missions hitting 503 preserves mission + uncertain job ===
    postModeRef.set "503"
    pollModeRef.set "running"
    let (st503, body503) ← sendRest app jwt "POST" "/api/control/missions"
      "{\"id\":\"m-flt05\",\"title\":\"FLT05\",\"backend\":\"claudecode\",\"remote_node_id\":\"mockr18\",\"prompt\":\"do work\"}" (some nowSec)
    check (st503 == 201 && body503.contains "\"status\":\"pending\"")
      s!"FLT-05 REST 503 preserves mission as pending (got {st503}: {body503})"
    let uncCnt ← count store.missionsDb
      "SELECT COUNT(*) FROM remote_node_jobs WHERE mission_id='m-flt05' AND state='uncertain';"
    check (uncCnt == 1) "FLT-05 persisted uncertain remote_node_jobs row"
    let origJobId ← queryCell store.missionsDb
      "SELECT job_id FROM remote_node_jobs WHERE mission_id='m-flt05' LIMIT 1;"
    check (!origJobId.isEmpty) "FLT-05 recorded original job_id"

    -- Duplicate submit must be fenced against uncertain job without calling node again
    let postsBefore ← postCountRef.get
    match ← submitRemoteMissionTurn store none (some rHub) (some bHub) remSup workDir
        { missionId := "m-flt05", targetNodeId := "mockr18", backend := "claudecode",
          workingDirectory := workDir, prompt := "dup", ownerUserId := adminId } nowSec with
    | .ok _ => throw (IO.userError "FLT-05 duplicate submit bypassed uncertain fence")
    | .error e => check (e.contains "existing_uncertain_job:") s!"FLT-05 fenced duplicate submit (got {e})"
    check ((← postCountRef.get) == postsBefore) "FLT-05 duplicate submit made zero extra POST /jobs"

    -- Startup reattach must not cancel uncertain row; periodic reconcile attaches exact original job
    pollModeRef.set "succeeded"
    let recCnt ← reconcileUncertainRemoteSubmissions store none (some rHub) (some bHub) remSup workDir (startup := false) (some (nowSec + 5))
    check (recCnt >= 1) s!"FLT-05 periodic reconciliation attached uncertain job (got {recCnt})"
    let mut flt05Done := false
    for _ in [:50] do
      let st ← queryCell store.missionsDb "SELECT status FROM missions WHERE id='m-flt05';"
      if st == "awaiting_user" || st == "completed" then flt05Done := true; break
      IO.sleep 40
    check flt05Done "FLT-05 reconciled original job completed cleanly"
    let finalJobId ← queryCell store.missionsDb "SELECT job_id FROM remote_node_jobs WHERE mission_id='m-flt05' LIMIT 1;"
    check (finalJobId == origJobId) "FLT-05 kept exact original job_id"

    -- FLT-05 via MCP start_mission hitting 503 settles receipt as uncertain (retryable:false) and preserves mission
    postModeRef.set "503"
    discard <| require (← execParamQuery store.projectsDb
      "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('r18-op',?1,'',?2,0,'operator');"
      #[adminId, s!"{nowSec + 3600}"])
    let opClaims : McpSessionClaims := {
      sessionId := "r18-op", missionId := "", role := "operator", project := "", expiresAt := nowSec + 3600
    }
    let rawMcpStart ← OrbCore.McpGateway.dispatchMcpToolCall store none (some rHub) (some bHub) {} workDir opClaims
      "start_mission" (.obj #[
        ("title", .str "MCP FLT05"), ("prompt", .str "probe"), ("backend", .str "claudecode"),
        ("remote_node_id", .str "mockr18"), ("idempotency_key", .str "k-mcp-flt05")
      ]) nowSec (remoteSup? := some remSup) (authenticatedUserId := adminId) (authenticatedAdmin := true)
    let .ok mcpStartJv := OrbBin.Json.parse rawMcpStart | throw (IO.userError "FLT-05 MCP start parse")
    check (mcpStartJv.fieldBool? "ok" == some false) "FLT-05 MCP start_mission returns non-ok on uncertain dispatch"
    let actState ← queryCell store.projectsDb
      "SELECT state FROM mcp_actions_v1 WHERE retry_key='k-mcp-flt05' LIMIT 1;"
    check (actState == "uncertain") s!"FLT-05 MCP action settled as uncertain (got {actState})"
    let mcpMissions ← count store.missionsDb "SELECT COUNT(*) FROM missions WHERE title='MCP FLT05';"
    check (mcpMissions == 1) "FLT-05 MCP start_mission preserved mission row"

    -- === FLT-06: Durable cancel_requested under partition + reattach + completion on heal ===
    missionSql store.missionsDb "m-flt06" "active" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, tags='[\"remote-node:mockr18\"]' WHERE id='m-flt06';" #[adminId])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
       "VALUES('job-flt06','m-flt06','mockr18','running','{\"generation\":1}','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');") #[])
    cancelModeRef.set "503"
    pollModeRef.set "running"
    let cOk1 ← cancelActiveRemoteJobForMission store none (some rHub) "m-flt06" "partition cancel"
    check (!cOk1) "FLT-06 cancel under 503 returns false (unconfirmed)"
    let cState1 ← queryCell store.missionsDb "SELECT state FROM remote_node_jobs WHERE job_id='job-flt06';"
    check (cState1 == "cancel_requested") s!"FLT-06 persisted durable cancel_requested (got {cState1})"
    -- Even if mission was marked cancelled, startup reattach adopts cancel_requested and finishes cancelling when node heals
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET status='cancelled' WHERE id='m-flt06';" #[])
    cancelModeRef.set "200"
    let reat ← reattachActiveRemoteJobsOnStartup store none (some rHub) (some bHub) remSup workDir
    check (reat >= 1) s!"FLT-06 startup reattach adopted cancel_requested job (got {reat})"
    let mut cancelledDone := false
    for _ in [:50] do
      let st ← queryCell store.missionsDb "SELECT state FROM remote_node_jobs WHERE job_id='job-flt06';"
      if st == "cancelled" then cancelledDone := true; break
      IO.sleep 40
    check (cancelledDone && (← cancelCountRef.get) >= 1) "FLT-06 healed node received POST /cancel and finalized cancelled"

    -- === FLT-07: Stale poller (gen=1) completing late cannot corrupt newer turn (gen=2) ===
    missionSql store.missionsDb "m-flt07" "active" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, session_id='ses-gen1', tags='[\"remote-node:mockr18\"]' WHERE id='m-flt07';" #[adminId])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
       "VALUES('job-flt07-old','m-flt07','mockr18','running','{\"generation\":1}','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');") #[])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,remote_job_id,updated_at) " ++
       "VALUES('run-flt07-1','m-flt07',1,'running','job-flt07-old','2026-11-26T00:00:00Z');") #[])
    staleDelayMsRef.set 300
    spawnRemoteJobPoller store none (some rHub) (some bHub) remSup workDir "m-flt07" "claudecode" "mockr18" "job-flt07-old" "" 0 1
    -- Immediately advance mission to generation 2 with a newer job
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET run_generation=2, status='active', session_id='ses-gen2' WHERE id='m-flt07';" #[])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
       "VALUES('job-flt07-new','m-flt07','mockr18','running','{\"generation\":2}','2026-11-26T00:00:01Z','2026-11-26T00:00:01Z');") #[])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO mission_runs(id,mission_id,generation,execution_state,remote_job_id,updated_at) " ++
       "VALUES('run-flt07-2','m-flt07',2,'running','job-flt07-new','2026-11-26T00:00:01Z');") #[])
    -- Wait for delayed gen=1 poller to finish
    let mut oldPollerDone := false
    for _ in [:50] do
      let st ← queryCell store.missionsDb "SELECT state FROM remote_node_jobs WHERE job_id='job-flt07-old';"
      if st == "succeeded" then oldPollerDone := true; break
      IO.sleep 30
    check oldPollerDone "FLT-07 stale poller recorded its own terminal state on old ledger row"
    let m7Status ← queryCell store.missionsDb "SELECT status FROM missions WHERE id='m-flt07';"
    let m7Sid ← queryCell store.missionsDb "SELECT session_id FROM missions WHERE id='m-flt07';"
    let r2State ← queryCell store.missionsDb "SELECT execution_state FROM mission_runs WHERE id='run-flt07-2';"
    let staleEvs ← count store.missionsDb
      "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-flt07' AND (COALESCE(content,'') LIKE '%STALE_OUTPUT_DO_NOT_APPLY%' OR COALESCE(payload,'') LIKE '%STALE_OUTPUT_DO_NOT_APPLY%');"
    check (m7Status == "active" && m7Sid == "ses-gen2" && r2State == "running" && staleEvs == 0)
      s!"FLT-07 stale poller did not corrupt gen=2 (status={m7Status} sid={m7Sid} r2={r2State} staleEvs={staleEvs})"

    -- === RUN-10: Idle-owner follow-up pump respects uncertain fence & rolls back definite 400 refusal ===
    missionSql store.missionsDb "m-run10" "awaiting_user" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, tags='[\"remote-node:mockr18\"]' WHERE id='m-run10';" #[adminId])
    discard <| require (← enqueueStructuredFollowup store "core" "q-run10-1" "m-run10" "queued followup after restart" "control" "2026-11-26T00:00:00Z")
    -- Fence check: while uncertain job exists, pump delivers 0
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) " ++
       "VALUES('job-run10-unc','m-run10','mockr18','uncertain','{}','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');") #[])
    let d0 ← tickRemoteFollowupPump store none (some rHub) (some bHub) remSup workDir nowSec
    check (d0 == 0) "RUN-10 pump respects uncertain job fence"
    discard <| require (← execParamQuery store.missionsDb "DELETE FROM remote_node_jobs WHERE job_id='job-run10-unc';" #[])
    -- Definite 400 refusal rolls claimed row back to phase=0, state='waiting' (zero message loss)
    postModeRef.set "400"
    let d1 ← tickRemoteFollowupPump store none (some rHub) (some bHub) remSup workDir (nowSec + 1)
    check (d1 == 0) "RUN-10 pump reports 0 delivered on definite 400 refusal"
    let qPhaseAfter400 ← queryCell store.missionsDb "SELECT phase FROM remote_message_queue WHERE message_id='q-run10-1';"
    check (qPhaseAfter400 == "0") s!"RUN-10 rolled back claimed row to phase=0 on definite refusal (got {qPhaseAfter400})"
    -- Recovery: 200 OK delivers follow-up cleanly and records real user_message seq
    let nowIso := formatEpochIso8601Utc nowSec
    discard <| require (← appendMissionEvent store "m-run10" "assistant_message" "{\"content\":\"prior\"}" nowIso)
    discard <| require (← appendMissionEvent store "m-run10" "assistant_message" "{\"content\":\"prior-2\"}" nowIso)
    postModeRef.set "200"
    pollModeRef.set "succeeded"
    let d2 ← tickRemoteFollowupPump store none (some rHub) (some bHub) remSup workDir (nowSec + 2)
    check (d2 == 1) s!"RUN-10 pump delivered waiting follow-up to idle remote mission (got {d2})"
    let qPhaseAfter200 ← queryCell store.missionsDb "SELECT phase FROM remote_message_queue WHERE message_id='q-run10-1';"
    let qDelivSeq ← queryCell store.missionsDb "SELECT delivered_seq FROM remote_message_queue WHERE message_id='q-run10-1';"
    let maxEvSeq ← queryCell store.missionsDb "SELECT COALESCE(MAX(seq),0) FROM mission_events WHERE mission_id='m-run10' AND event_type='user_message';"
    check (qPhaseAfter200 == "2" && qDelivSeq == maxEvSeq && qDelivSeq != "1")
      s!"RUN-10 marked delivered follow-up phase=2 with real user_message seq (phase={qPhaseAfter200} delivSeq={qDelivSeq} maxEvSeq={maxEvSeq})"
    IO.sleep 150

    -- RUN-10 / FUP-02: Queued `/goal` follow-up must roll back `goal_mode=0` on definite 400 rejection
    missionSql store.missionsDb "m-run10-goal" "awaiting_user" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET tags='[\"remote-node:mockr18\"]', backend='codex', goal_mode=0, goal_objective='' WHERE id='m-run10-goal';" #[])
    discard <| require (← enqueueStructuredFollowup store "core" "q-run10-goal" "m-run10-goal" "/goal ship liveness" "rest" nowIso)
    postModeRef.set "400"
    let dg1 ← tickRemoteFollowupPump store none (some rHub) (some bHub) remSup workDir (nowSec + 3)
    check (dg1 == 0) "RUN-10 /goal pump reports 0 on 400"
    let gModeAfter400 ← queryCell store.missionsDb "SELECT COALESCE(goal_mode,0) FROM missions WHERE id='m-run10-goal';"
    let gQPhaseAfter400 ← queryCell store.missionsDb "SELECT phase FROM remote_message_queue WHERE message_id='q-run10-goal';"
    check (gModeAfter400 == "0" && gQPhaseAfter400 == "0")
      s!"RUN-10 /goal definite 400 rolled back goal_mode and queue claim (goal_mode={gModeAfter400} phase={gQPhaseAfter400})"
    postModeRef.set "200"
    let dg2 ← tickRemoteFollowupPump store none (some rHub) (some bHub) remSup workDir (nowSec + 4)
    check (dg2 == 1) s!"RUN-10 /goal pump delivered after recovery (got {dg2})"
    let gModeAfter200 ← queryCell store.missionsDb "SELECT COALESCE(goal_mode,0) FROM missions WHERE id='m-run10-goal';"
    let gQPhaseAfter200 ← queryCell store.missionsDb "SELECT phase FROM remote_message_queue WHERE message_id='q-run10-goal';"
    let gQDelivSeq ← queryCell store.missionsDb "SELECT delivered_seq FROM remote_message_queue WHERE message_id='q-run10-goal';"
    check (gModeAfter200 == "1" && gQPhaseAfter200 == "2" && gQDelivSeq != "0" && !gQDelivSeq.isEmpty)
      s!"RUN-10 /goal activated goal_mode=1 and transitioned queue item to phase=2 with delivered_seq>0 (goal={gModeAfter200} phase={gQPhaseAfter200} seq={gQDelivSeq})"
    IO.sleep 150
  finally
    closeCoreStore store
    stopRef.set true
    let _ := mockTask.get
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODE_MOCKR18_TOKEN"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_PUBLIC_URL"
    discard <| (IO.FS.removeDirAll workDir).toBaseIO

/-- `RUN-01` (shutdown drain), `RUN-02` (local supervisor stuck/exited + background watcher),
    and `RUN-03` (Core systemd scope reaper excluding `orb-node-*` and active local scopes). -/
def testLocalSupervisionAndScopes (root : String) : IO Unit := do
  let workDir := s!"{root}/local-sup"
  IO.FS.createDirAll workDir
  let .ok store ← openCoreStore s!"{workDir}/store" 0 "prod"
    | throw (IO.userError "r18 liveness: open store for local sup")
  try
    let bHub ← newBroadcastHub
    let mgr ← newWarmHarnessManager
    let (app, _, _) ← mkTestApp store workDir none (some bHub) none none (some mgr)
    let nowSec : UInt64 := 1795001000
    let nowIso := formatEpochIso8601Utc nowSec

    -- Create helper script that sleeps quietly without producing stdout
    let sleeperPath := s!"{workDir}/silent_cli.sh"
    IO.FS.writeFile sleeperPath "#!/bin/sh\nsleep 30\n"
    discard <| IO.Process.output { cmd := "/bin/chmod", args := #["+x", sleeperPath] }

    -- 1. RUN-02: Live-but-silent process past stuck threshold is terminated, marked local_harness_stuck, and proxy token revoked
    missionSql store.missionsDb "m-stuck" "active" "local" 1
    addRun store.missionsDb "r-stuck" "m-stuck" "1" "running"
    discard <| require (← mintMissionProxyToken store "m-stuck" "" (nowSec + 86400))
    let .ok _ ← startHarnessTurn mgr "m-stuck" "codex" sleeperPath workDir "hang" 1 none none none .bypassPermissions "local"
      | throw (IO.userError "r18 liveness: startHarnessTurn stuck failed")
    touchRunProgress mgr "m-stuck" (nowSec - 120)
    let stuckPid? ← mgr.mu.atomically do
      let gs ← mgr.activeGroupsRef.get
      pure ((gs.find? (fun p => p.1 == "m-stuck")).map fun p => p.2.pid)
    let some stuckPid := stuckPid? | throw (IO.userError "r18 liveness: stuck process not registered")
    let supCnt ← tickLocalHarnessSupervisor app nowIso (some nowSec) (some 30)
    check (supCnt == 1) s!"RUN-02 stuck supervisor caught silent live run (got {supCnt})"
    let stuckReason ← queryCell store.missionsDb "SELECT terminal_reason FROM missions WHERE id='m-stuck';"
    let stuckTokLive ← count store.missionsDb "SELECT COUNT(*) FROM mission_proxy_tokens WHERE mission_id='m-stuck' AND revoked=0;"
    check (stuckReason == "local_harness_stuck" && stuckTokLive == 0)
      s!"RUN-02 set local_harness_stuck and revoked proxy token (reason={stuckReason} liveToks={stuckTokLive})"
    IO.sleep 100
    let stuckObs ← OrbCore.HarnessSessionRegistry.observeProcStat stuckPid.toInt.toNat.toUInt32
    check (stuckObs.procMissing != 0 || stuckObs.isZombieOrDeadState != 0) "RUN-02 terminated stuck process"

    -- 2. RUN-01: drainLocalHarnessRunsOnShutdown stops real active local process, revokes proxy token, and writes core_shutdown receipt
    missionSql store.missionsDb "m-drain" "active" "local" 1
    addRun store.missionsDb "r-drain" "m-drain" "1" "running"
    discard <| require (← mintMissionProxyToken store "m-drain" "" (nowSec + 86400))
    let .ok _ ← startHarnessTurn mgr "m-drain" "codex" sleeperPath workDir "shutdown" 1 none none none .bypassPermissions "local"
      | throw (IO.userError "r18 liveness: startHarnessTurn drain failed")
    let drainPid? ← mgr.mu.atomically do
      let gs ← mgr.activeGroupsRef.get
      pure ((gs.find? (fun p => p.1 == "m-drain")).map fun p => p.2.pid)
    let some drainPid := drainPid? | throw (IO.userError "r18 liveness: drain process not registered")
    let drained ← drainLocalHarnessRunsOnShutdown app
    check (drained == 1) s!"RUN-01 shutdown drained active local run (got {drained})"
    let drainReason ← queryCell store.missionsDb "SELECT terminal_reason FROM missions WHERE id='m-drain';"
    let drainRec ← count store.missionsDb "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-drain' AND event_type='recovery_receipt';"
    let drainTokLive ← count store.missionsDb "SELECT COUNT(*) FROM mission_proxy_tokens WHERE mission_id='m-drain' AND revoked=0;"
    check (drainReason == "core_shutdown" && drainRec == 1 && drainTokLive == 0)
      s!"RUN-01 recorded core_shutdown + receipt + revoked token (reason={drainReason} rec={drainRec} toks={drainTokLive})"
    IO.sleep 100
    let drainObs ← OrbCore.HarnessSessionRegistry.observeProcStat drainPid.toInt.toNat.toUInt32
    check (drainObs.procMissing != 0 || drainObs.isZombieOrDeadState != 0) "RUN-01 terminated drained local process"

    -- 3. RUN-02: tickBackgroundShellWatcher wakes same-boot waiting_background on terminal job and arms resume continuation
    missionSql store.missionsDb "m-bg" "waiting_background" "managed" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET node_boot_epoch=CAST(?1 AS INTEGER), placement_job_id='bg-job-1' WHERE id='m-bg';" #[s!"{store.bootEpoch}"])
    discard <| require (← execParamQuery store.missionsDb
      ("CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', " ++
       "node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
       "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');") #[])
    discard <| require (← execParamQuery store.missionsDb
      "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('bg-job-1','m-bg','n1','succeeded','{}','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');" #[])
    let bgWoken ← tickBackgroundShellWatcher app nowSec (some 60)
    check (bgWoken == 1) s!"RUN-02 background watcher woke waiting_background mission (got {bgWoken})"
    let bgSt ← queryCell store.missionsDb "SELECT status FROM missions WHERE id='m-bg';"
    let bgEv ← count store.missionsDb "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-bg' AND event_type='background_task_completed';"
    let bgCont ← count store.missionsDb "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-bg' AND phase=1 AND source='bg-watcher';"
    check (bgSt == "awaiting_user" && bgEv == 1 && bgCont == 1)
      s!"RUN-02 background mission settled to awaiting_user with event + armed continuation (st={bgSt} ev={bgEv} cont={bgCont})"

    -- 4. RUN-03: parseActiveEnterMonoToEpoch + reapOrphanedCoreScopes reaps terminal/missing/zombie-aged scopes
    -- and spares fresh active local & orb-node-* scopes
    let parsedStart := parseActiveEnterMonoToEpoch "3600000000\n" 50400 nowSec -- 50400 - 3600 = 46800s (13h) old
    check (parsedStart == nowSec - 46800) s!"RUN-03 parseActiveEnterMonoToEpoch computed exact age (got {parsedStart})"
    missionSql store.missionsDb "m-sc-active" "active" "local" 1
    missionSql store.missionsDb "m-sc-zombie" "active" "local" 1
    missionSql store.missionsDb "m-sc-done" "completed" "local" 1
    let stoppedRef ← IO.mkRef (#[] : Array String)
    let fakeScopes : IO (Array CoreScopeEntry) := pure #[
      { unitName := "orb-mission-m-sc-active.scope", missionId := "m-sc-active", startedSec := nowSec - 60, isNodeScope := false },
      { unitName := "orb-mission-m-sc-zombie.scope", missionId := "m-sc-zombie", startedSec := parsedStart, isNodeScope := false },
      { unitName := "orb-mission-m-sc-done.scope", missionId := "m-sc-done", startedSec := nowSec - 60, isNodeScope := false },
      { unitName := "orb-mission-m-sc-ghost.scope", missionId := "m-sc-ghost", startedSec := nowSec - 60, isNodeScope := false },
      { unitName := "orb-node-job-99.scope", missionId := "m-sc-done", startedSec := nowSec - 99999, isNodeScope := true }
    ]
    let fakeStop (u : String) : IO Bool := do stoppedRef.modify (·.push u); return true
    let scReaped ← reapOrphanedCoreScopes app nowSec (some fakeScopes) (some fakeStop)
    let stopped ← stoppedRef.get
    check (scReaped == 3 && stopped.contains "orb-mission-m-sc-done.scope" && stopped.contains "orb-mission-m-sc-ghost.scope" &&
           stopped.contains "orb-mission-m-sc-zombie.scope" &&
           !stopped.contains "orb-mission-m-sc-active.scope" && !stopped.contains "orb-node-job-99.scope")
      s!"RUN-03 scope reaper stopped orphaned + zombie-aged Core scopes only (stopped={stopped})"
  finally
    closeCoreStore store
    discard <| (IO.FS.removeDirAll workDir).toBaseIO

/-- `RUN-05` + `RUN-06`: Live SSE `attachSseEventBridge` + `Last-Event-ID` resume +
    `/api/projects/:slug/context/stream`, live PTY WebSocket `/api/console/ws` surviving
    >2.1s idle, live `/api/monitoring/ws`, and `/api/desktop/stream` `501 Not Implemented`. -/
def testLiveSseAndWebSocketTransports (root : String) : IO Unit := do
  let workDir := s!"{root}/transports"
  IO.FS.createDirAll workDir
  let .ok store ← openCoreStore s!"{workDir}/store" 0 "prod"
    | throw (IO.userError "r18 liveness: open store for transports")
  let bHub ← newBroadcastHub
  let detachBridge ← attachSseEventBridge store bHub
  let (app, adminId, jwt) ← mkTestApp store workDir none (some bHub)
  let (listenFd, port) ← bindLoopbackEphemeral
  let stopSrvRef ← IO.mkRef false
  let srvTask ← IO.asTask (prio := .dedicated) do
    while !(← stopSrvRef.get) do
      match ← tcpAcceptPoll listenFd 40 with
      | .error _ => pure ()
      | .ok cfd =>
        discard <| IO.asTask (prio := .dedicated) (handleClientConn app cfd false)
    discard <| closeFd listenFd
  try
    let nowIso := "2026-11-27T10:00:00Z"
    missionSql store.missionsDb "m-sse" "active" "local" 1
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET owner_user_id=?1 WHERE id='m-sse';" #[adminId])
    discard <| require (← appendMissionEvent store "m-sse" "user_message" "{\"content\":\"seed-1\"}" nowIso)

    -- 1. RUN-05: Open /api/control/missions/m-sse/stream, then append live event -> receives real SQLite seq id: 2
    let .ok sseFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-05 connect SSE failed")
    try
      let sseReq := s!"GET /api/control/missions/m-sse/stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\nAccept: text/event-stream\r\n\r\n".toUTF8
      discard <| writeAll sseFd sseReq false
      let initBuf ← readUntilMs sseFd 2000 fun b => ((String.fromUTF8? b).getD "").contains "seed-1"
      let initStr := (String.fromUTF8? initBuf).getD ""
      check (initStr.contains "event: snapshot" && initStr.contains "id: 1") s!"RUN-05 initial SSE snapshot missing id:1: {initStr}"
      -- Trigger live event strictly via Store.appendMissionEvent (bridged automatically!)
      discard <| require (← appendMissionEvent store "m-sse" "assistant_message" "{\"content\":\"live-after-open\"}" nowIso)
      let liveBuf ← readUntilMs sseFd 2000 fun b => ((String.fromUTF8? b).getD "").contains "live-after-open"
      let liveStr := (String.fromUTF8? liveBuf).getD ""
      check (liveStr.contains "id: 2" && liveStr.contains "live-after-open")
        s!"RUN-05 live bridged SSE frame missing real seq id:2: {liveStr}"
    finally discard <| closeFd sseFd

    -- 2. RUN-05: Reconnect with Last-Event-ID: 1 replays only seq 2 (no duplicate seed-1)
    let .ok sseFd2 ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-05 reconnect SSE failed")
    try
      let sseReq2 := s!"GET /api/control/missions/m-sse/stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\nLast-Event-ID: 1\r\n\r\n".toUTF8
      discard <| writeAll sseFd2 sseReq2 false
      let resBuf ← readUntilMs sseFd2 2000 fun b => ((String.fromUTF8? b).getD "").contains "live-after-open"
      let resStr := (String.fromUTF8? resBuf).getD ""
      check (resStr.contains "id: 2" && !resStr.contains "seed-1")
        s!"RUN-05 Last-Event-ID reconnect duplicated seq 1: {resStr}"
    finally discard <| closeFd sseFd2

    -- 3. RUN-05: /api/projects/:slug/context/stream emits event: changed with monotonic id
    discard <| require (← execParamQuery store.projectsDb
      "INSERT INTO projects(slug,name,title) VALUES('p-sse','p-sse','P SSE');" #[])
    discard <| require (← execParamQuery store.projectsDb
      "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES('p-sse',?1,?2);" #[adminId, nowIso])
    let .ok ctxFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-05 connect context SSE failed")
    try
      let ctxReq := s!"GET /api/projects/p-sse/context/stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\n\r\n".toUTF8
      discard <| writeAll ctxFd ctxReq false
      let cInit ← readUntilMs ctxFd 2000 fun b => ((String.fromUTF8? b).getD "").contains "id: 1"
      let cInitStr := (String.fromUTF8? cInit).getD ""
      check (cInitStr.contains "event: changed" && cInitStr.contains "id: 1") s!"RUN-05 context stream sent initial frame: {cInitStr}"
      discard <| require (← execParamQuery store.projectsDb
        "INSERT OR REPLACE INTO context_heads(project_slug,revision) VALUES('p-sse',2);" #[])
      let cChg ← readUntilMs ctxFd 2500 fun b => ((String.fromUTF8? b).getD "").contains "id: 2"
      let cChgStr := (String.fromUTF8? cChg).getD ""
      check (cChgStr.contains "event: changed" && cChgStr.contains "id: 2")
        s!"RUN-05 context stream missed live change frame: {cChgStr}"
    finally discard <| closeFd ctxFd

    -- 3b. RUN-05: emitMissionPresentationNotice (__presentation__) AND persisted activity/turn events
    -- emit sanitized `event: mission_presentation` (NO `id: 0`, NO `owner_uid`/`shared_uids`) on
    -- `?profile=presentation`, while `?kinds=assistant_message` does NOT leak `mission_presentation`,
    -- and `mission_deleted` for an unowned mission still delivers to admin.
    let .ok presFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-05 connect presentation SSE failed")
    let .ok kindsFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-05 connect kinds-filtered SSE failed")
    try
      let presReq := s!"GET /api/control/stream?profile=presentation HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\nAccept: text/event-stream\r\n\r\n".toUTF8
      discard <| writeAll presFd presReq false
      discard <| readUntilMs presFd 1500 fun b => ((String.fromUTF8? b).getD "").contains "event:"
      let kindsReq := s!"GET /api/control/stream?kinds=assistant_message HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\nAccept: text/event-stream\r\n\r\n".toUTF8
      discard <| writeAll kindsFd kindsReq false
      discard <| readUntilMs kindsFd 1500 fun b => ((String.fromUTF8? b).getD "").contains "event:"
      emitMissionPresentationNotice store "m-sse" "mission_updated" adminId #["secret-peer-uid"] ""
      discard <| require (← appendMissionEvent store "m-sse" "tool_call" "{\"tool_name\":\"bash\"}" nowIso)
      discard <| require (← appendMissionEvent store "m-sse" "assistant_message" "{\"content\":\"pres-turn-done\"}" nowIso)
      emitMissionPresentationNotice store "m-deleted-unowned" "mission_deleted" "" #[] ""
      let pBuf ← readUntilMs presFd 2500 fun b =>
        let s := (String.fromUTF8? b).getD ""
        s.contains "mission_updated" && s.contains "mission_activity" && s.contains "assistant_message" && s.contains "m-deleted-unowned"
      let pStr := (String.fromUTF8? pBuf).getD ""
      check (pStr.contains "event: mission_presentation" && pStr.contains "\"mission_id\":\"m-sse\"" &&
             pStr.contains "\"kind\":\"mission_activity\"" && pStr.contains "\"kind\":\"assistant_message\"" &&
             pStr.contains "\"mission_id\":\"m-deleted-unowned\"" &&
             !pStr.contains "__presentation__" && !pStr.contains "id: 0" &&
             !pStr.contains "owner_uid" && !pStr.contains "shared_uids" && !pStr.contains "secret-peer-uid")
        s!"RUN-05 presentation SSE missing derived/deleted events or leaked ACL/id:0: {pStr}"
      let kBuf ← readUntilMs kindsFd 2000 fun b => ((String.fromUTF8? b).getD "").contains "pres-turn-done"
      let kStr := (String.fromUTF8? kBuf).getD ""
      check (kStr.contains "pres-turn-done" && !kStr.contains "event: mission_presentation")
        s!"RUN-05 ?kinds=assistant_message must NOT leak mission_presentation frames: {kStr}"
    finally
      discard <| closeFd presFd
      discard <| closeFd kindsFd

    -- 4. RUN-06: Live PTY WebSocket on /api/console/ws speaks TerminalSocket wire protocol
    -- (`{"t":"r",...}` / `{"t":"i",...}`, raw UTF-8 PTY output with NO JSON greeting/wrapper,
    -- ignores unknown JSON control objects, and survives >2.1s idle).
    let .ok wsFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-06 connect PTY WS failed")
    try
      let wsReq :=
        (s!"GET /api/console/ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\n" ++
         "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").toUTF8
      discard <| writeAll wsFd wsReq false
      let hsBuf ← readUntilMs wsFd 2000 fun b => (findHeaderEnd b).isSome
      let hsEnd := (findHeaderEnd hsBuf).getD 0
      let hsHead := (String.fromUTF8? (hsBuf.extract 0 hsEnd)).getD ""
      check (hsHead.contains "101 Switching Protocols") s!"RUN-06 PTY WS did not upgrade 101: {hsHead}"
      -- Sleep >2.1s idle to prove the legacy 64-step / ~1.9s cap is gone
      IO.sleep 2200
      discard <| writeAll wsFd (encodeClientWsText "{\"t\":\"r\",\"c\":100,\"r\":30}".toUTF8) false
      discard <| writeAll wsFd (encodeClientWsText "{\"t\":\"noop\",\"ignored\":true}".toUTF8) false
      discard <| writeAll wsFd (encodeClientWsText "{\"t\":\"i\",\"d\":\"echo R18_PTY_LIVE_OK\\n\"}".toUTF8) false
      let mut rx := hsBuf.extract hsEnd hsBuf.size
      let mut sawOutput := false
      let mut sawJsonWrapper := false
      let mut sawLeakedNoop := false
      let deadline := (← IO.monoMsNow) + 3000
      while (← IO.monoMsNow) < deadline && !sawOutput do
        match decodeFramePrefix rx false with
        | .ok (some (frm, consumed)) =>
          rx := rx.extract consumed rx.size
          let txt := (String.fromUTF8? frm.payload).getD ""
          if txt.contains "\"type\":\"ready\"" || txt.contains "\"type\":\"output\"" then sawJsonWrapper := true
          if txt.contains "\"t\":\"noop\"" then sawLeakedNoop := true
          if txt.contains "R18_PTY_LIVE_OK" then sawOutput := true
        | _ =>
          match ← pollReadable wsFd 50 with
          | .error _ => pure ()
          | .ok () =>
            let chunk ← readStreamChunk wsFd 16384
            if chunk.isEmpty then break
            rx := rx ++ chunk
      check (sawOutput && !sawJsonWrapper && !sawLeakedNoop)
        s!"RUN-06 PTY WS must speak raw TerminalSocket protocol (ok={sawOutput} wrapper={sawJsonWrapper} noop={sawLeakedNoop})"
      discard <| writeAll wsFd encodeClientWsClose false
    finally discard <| closeFd wsFd

    -- 4b. RUN-06: /api/workspaces/:id/shell validates workspace existence (404) & container type (501) BEFORE 101
    discard <| require (← execParamQuery store.missionsDb
      "INSERT INTO workspaces(id,name,kind,path,owner_user_id) VALUES('ws-cont','cont','container','/tmp',?1);" #[adminId])
    let (wsMissSt, _) ← sendRest app jwt "GET" "/api/workspaces/no-such-ws/shell" ""
    check (wsMissSt == 404) s!"RUN-06 missing workspace shell expected 404 (got {wsMissSt})"
    let (wsContSt, _) ← sendRest app jwt "GET" "/api/workspaces/ws-cont/shell" ""
    check (wsContSt == 501) s!"RUN-06 container workspace shell expected 501 (got {wsContSt})"

    -- 5. RUN-06: /api/monitoring/ws requires admin (403 for member), negotiates `sandboxed` subprotocol,
    -- emits Machines.tsx schema (`cpu_percent`, `memory_used`, `memory_total`, `timestamp_ms`), and honors pause/resume.
    let nowAuth ← coreEpochSec
    discard <| require (← execParamQuery store.missionsDb
      "INSERT OR REPLACE INTO users(id,username,role,password_hash,session_epoch,disabled,created_at,updated_at) VALUES('u-mem-mon','memmon','member','x',1,0,?1,?1);"
      #[s!"{nowAuth}"])
    let memJwt := mintSessionTokenV2 "r18-liveness-jwt-secret-0123456789abcdef" "u-mem-mon" "member" 1 (nowAuth + 3600)
    let (monMemSt, _) ← sendRest app memJwt "GET" "/api/monitoring/ws" "" (some nowAuth)
    check (monMemSt == 403) s!"RUN-06 /api/monitoring/ws must reject non-admin member with 403 (got {monMemSt})"

    let .ok monFd ← tcpConnect "127.0.0.1" port | throw (IO.userError "RUN-06 connect monitoring WS failed")
    try
      let monReq :=
        (s!"GET /api/monitoring/ws?interval_ms=150 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {jwt}\r\n" ++
         "Sec-WebSocket-Protocol: sandboxed\r\n" ++
         "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").toUTF8
      discard <| writeAll monFd monReq false
      let hsBuf ← readUntilMs monFd 2000 fun b => (findHeaderEnd b).isSome
      let hsEnd := (findHeaderEnd hsBuf).getD 0
      let hsHead := (String.fromUTF8? (hsBuf.extract 0 hsEnd)).getD ""
      check (hsHead.contains "101 Switching Protocols" && hsHead.contains "Sec-WebSocket-Protocol: sandboxed")
        s!"RUN-06 monitoring WS failed sandboxed subprotocol negotiation: {hsHead}"
      let mut rx := hsBuf.extract hsEnd hsBuf.size
      let mut metricFrames : Nat := 0
      let deadline := (← IO.monoMsNow) + 2000
      while (← IO.monoMsNow) < deadline && metricFrames < 2 do
        match decodeFramePrefix rx false with
        | .ok (some (frm, consumed)) =>
          rx := rx.extract consumed rx.size
          let txt := (String.fromUTF8? frm.payload).getD ""
          if let .ok jv := OrbBin.Json.parse txt then
            if (jv.field? "cpu_percent").isSome && (jv.field? "memory_used").isSome &&
               (jv.field? "memory_total").isSome && (jv.fieldUInt64? "timestamp_ms").isSome then
              metricFrames := metricFrames + 1
        | _ =>
          match ← pollReadable monFd 50 with
          | .error _ => pure ()
          | .ok () =>
            let chunk ← readStreamChunk monFd 16384
            if chunk.isEmpty then break
            rx := rx ++ chunk
      check (metricFrames >= 2) s!"RUN-06 monitoring WS streamed Machines.tsx host metrics frames (got {metricFrames})"
      -- Pause + resume coalesced frames
      discard <| writeAll monFd (encodeClientWsText "{\"t\":\"pause\"}".toUTF8 ++ encodeClientWsText "{\"t\":\"resume\"}".toUTF8) false
      discard <| writeAll monFd encodeClientWsClose false
    finally discard <| closeFd monFd

    -- 6. RUN-06: /api/desktop/stream returns explicit 501 Not Implemented
    let (deskSt, deskBody) ← sendRest app jwt "GET" "/api/desktop/stream" ""
    check (deskSt == 501 && deskBody.contains "not_implemented")
      s!"RUN-06 /api/desktop/stream expected 501 not_implemented (got {deskSt}: {deskBody})"
  finally
    detachBridge
    stopSrvRef.set true
    let _ := srvTask.get
    closeCoreStore store
    discard <| (IO.FS.removeDirAll workDir).toBaseIO

/-- `RUN-11` (fair continuation scheduling without blocked-prefix starvation + `projectsDb.remote_jobs`),
    `RUN-12` (telemetry single-flight flush coalescing + multi-batch drain). -/
def testContinuationsAndTelemetry (root : String) : IO Unit := do
  let workDir := s!"{root}/cont-telem"
  IO.FS.createDirAll workDir
  let .ok store ← openCoreStore s!"{workDir}/store" 0 "prod"
    | throw (IO.userError "r18 liveness: open store for cont/telem")
  try
    let .ok () ← ensureQueueContSchema store
      | throw (IO.userError "r18 liveness: ensureQueueContSchema")
    let remSup ← newRemoteJobSupervisor "r18-liveness-jwt-secret-0123456789abcdef" false
    let nowSec : UInt64 := 1795002000

    -- === RUN-11: 40 busy-owner + 40 paused-owner due rows + 40 future-due non-terminal job rows
    -- + >512 historical terminal rows in projectsDb.remote_jobs must not starve idle owner or job wakeup ===
    missionSql store.missionsDb "m-busy" "active" "local" 1
    missionSql store.missionsDb "m-paused" "paused" "local" 1
    missionSql store.missionsDb "m-idle" "awaiting_user" "local" 1
    missionSql store.missionsDb "m-projjob" "awaiting_user" "local" 1
    for i in [:40] do
      discard <| require (← execParamQuery store.missionsDb
        ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,created_at,updated_at) " ++
         "VALUES(?1,'m-busy',1,1,CAST(?2 AS INTEGER),'time','test','busy',?1,'','mcp','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');")
        #[s!"c-busy-{i}", s!"{nowSec - 100 + i.toUInt64}"])
      discard <| require (← execParamQuery store.missionsDb
        ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,created_at,updated_at) " ++
         "VALUES(?1,'m-paused',1,1,CAST(?2 AS INTEGER),'time','test','paused',?1,'','mcp','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');")
        #[s!"c-paused-{i}", s!"{nowSec - 100 + i.toUInt64}"])
    for i in [:40] do
      discard <| require (← execParamQuery store.missionsDb
        ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,created_at,updated_at) " ++
         "VALUES(?1,'m-idle',1,1,CAST(?2 AS INTEGER),'durable_job_terminal','test','waitjob',?1,?3,'mcp','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');")
        #[s!"c-fut-{i}", s!"{nowSec + 9999}", s!"job-still-running-{i}"])
    -- Continuation on idle owner is due now
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,created_at,updated_at) " ++
       "VALUES('c-idle-ok','m-idle',1,1,CAST(?1 AS INTEGER),'time','test','wake idle','c-idle-ok','','mcp','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');")
      #[s!"{nowSec - 1}"])
    -- Populate 520 historical terminal rows in projectsDb.remote_jobs BEFORE the watched 521st job
    discard <| require (← execParamQuery store.projectsDb
      ("CREATE TABLE IF NOT EXISTS remote_jobs (job_id TEXT PRIMARY KEY, state TEXT NOT NULL DEFAULT 'queued');") #[])
    discard <| require (← withImmediateTx store.projectsDb do
      for i in [:520] do
        discard <| execParamQueryUnlocked store.projectsDb
          "INSERT OR REPLACE INTO remote_jobs(job_id,state) VALUES(?1,'succeeded');" #[s!"hist-job-{i}"]
      execParamQueryUnlocked store.projectsDb
        "INSERT OR REPLACE INTO remote_jobs(job_id,state) VALUES('pjob-done-521','succeeded');" #[])
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,created_at,updated_at) " ++
       "VALUES('c-pjob','m-projjob',1,1,CAST(?1 AS INTEGER),'durable_job_terminal','test','wake projjob','c-pjob','pjob-done-521','mcp','2026-11-26T00:00:00Z','2026-11-26T00:00:00Z');")
      #[s!"{nowSec + 9999}"])

    let firedRef ← IO.mkRef (#[] : Array String)
    let launcher : MissionRecord → String → Option String → WakeupClaim → IO Bool := fun mr _ _ claim => do
      firedRef.modify (·.push s!"{mr.id}:{claim.id}")
      return true
    let firedN ← tickContinuationScheduler store none none none remSup none workDir (some launcher) (some nowSec)
    let fired ← firedRef.get
    check (firedN == 2 && fired.contains "m-idle:c-idle-ok" && fired.contains "m-projjob:c-pjob")
      s!"RUN-11 fired idle owner + projectsDb terminal job without starvation (n={firedN} fired={fired})"

    -- === RUN-12: Telemetry concurrent flush coalescing + multi-batch drain ===
    let (ingFd, ingPort) ← bindLoopbackEphemeral
    let stopIngRef ← IO.mkRef false
    let rxIdsRef ← IO.mkRef (#[] : Array String)
    let postsRef ← IO.mkRef (0 : Nat)
    let ingTask ← IO.asTask (prio := .dedicated) do
      while !(← stopIngRef.get) do
        match ← tcpAcceptPoll ingFd 40 with
        | .error _ => pure ()
        | .ok cfd =>
          match ← readHttpRequestFromFd cfd none 2000 with
          | .error _ => discard <| closeFd cfd
          | .ok req =>
            -- Slow ingest to guarantee overlap between concurrent flush calls
            IO.sleep 120
            let _ ← postsRef.modifyGet fun c => (c + 1, c + 1)
            if let .ok jv := OrbBin.Json.parseBytes req.bodySlice.toByteArray then
              if let some evs := jv.fieldArr? "events" then
                rxIdsRef.modify fun acc =>
                  evs.foldl (fun a e => a.push ((e.fieldStr? "event_id").getD "")) acc
            let wire := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".toUTF8
            discard <| writeAll cfd wire false
            discard <| closeFd cfd
      discard <| closeFd ingFd
    try
      let sink ← newTelemetrySink
      syncSinkTarget sink (some { url := s!"http://127.0.0.1:{ingPort}", ns := "r18", token := "tok", prompts := false })
      let mkEv (id : String) : JVal := .obj #[
        ("schema", .str "orb.page.v1"), ("client", .str "desktop"),
        ("event_id", .str id), ("dwell_ms", .nat 5000)
      ]
      let _ ← acceptClientTelemetryBatch sink (#["e1","e2","e3","e4","e5"].map mkEv) none none nowSec
      let t1 ← IO.asTask (prio := .dedicated) (flushTelemetryOnce sink nowSec)
      IO.sleep 25
      let t2 ← IO.asTask (prio := .dedicated) (flushTelemetryOnce sink nowSec)
      -- Enqueue 3 more while flush #1 is in-flight
      let _ ← acceptClientTelemetryBatch sink (#["e6","e7","e8"].map mkEv) none none nowSec
      let _ ← IO.wait t1
      let _ ← IO.wait t2
      let _ ← drainTelemetryBatches sink nowSec 5
      let rx1 ← rxIdsRef.get
      check (rx1.size == 8 && #["e1","e2","e3","e4","e5","e6","e7","e8"].all rx1.contains)
        s!"RUN-12 coalesced concurrent flushes without duplicates or drops (got {rx1.size}: {rx1})"
      -- Multi-batch drain (>200 events)
      rxIdsRef.set #[]
      let mut b1 : Array JVal := #[]
      for i in [:120] do b1 := b1.push (mkEv s!"mb-a-{i}")
      let mut b2 : Array JVal := #[]
      for i in [:105] do b2 := b2.push (mkEv s!"mb-b-{i}")
      let _ ← acceptClientTelemetryBatch sink b1 none none nowSec
      let _ ← acceptClientTelemetryBatch sink b2 none none nowSec
      let drained ← drainTelemetryBatches sink nowSec 10
      let rem ← sink.mu.atomically do pure (← get).events.size
      check (drained == 225 && rem == 0 && (← rxIdsRef.get).size == 225)
        s!"RUN-12 drained 225 events across multiple batches (drained={drained} rem={rem})"
    finally
      stopIngRef.set true
      let _ := ingTask.get
  finally
    closeCoreStore store
    discard <| (IO.FS.removeDirAll workDir).toBaseIO

/-- `MCP-03` (canonical fingerprints, keyed `import_mission`/`schedule_job_wakeup`/`update_project_status`,
    board conflict), `MCP-07` (`answer_mission_question` live wire translation + error settlement,
    `ask_mission` null `thread_id`, `send_message_to_mission` fail-closed & unsupported modes),
    and `FUP-01`/`FUP-02` (job-bound protection, table-wide `MIN(sequence)-1` promotion, terminal & missing-sup guards). -/
def testMcpAndQueueContracts (root : String) : IO Unit := do
  let workDir := s!"{root}/mcp-queue"
  IO.FS.createDirAll workDir
  let .ok store ← openCoreStore s!"{workDir}/store" 0 "prod"
    | throw (IO.userError "r18 liveness: open store for mcp/queue")
  try
    let .ok () ← ensureQueueContSchema store
      | throw (IO.userError "r18 liveness: ensureQueueContSchema")
    let bHub ← newBroadcastHub
    let remSup ← newRemoteJobSupervisor "r18-liveness-jwt-secret-0123456789abcdef" false
    let mgr ← newWarmHarnessManager
    let (app, adminId, jwt) ← mkTestApp store workDir none (some bHub) none (some remSup) (some mgr)
    let nowSec ← coreEpochSec
    let nowIso := formatEpochIso8601Utc nowSec

    discard <| require (← execParamQuery store.projectsDb
      "INSERT INTO projects(slug,name,title) VALUES('p-mcp03','p-mcp03','MCP03');" #[])
    discard <| require (← execParamQuery store.projectsDb
      "INSERT OR IGNORE INTO project_owners(slug,owner_user_id,created_at) VALUES('p-mcp03',?1,?2);" #[adminId, nowIso])
    discard <| require (← execParamQuery store.projectsDb
      "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('s-op',?1,'',?2,0,'operator');"
      #[adminId, s!"{nowSec + 3600}"])
    let opClaims : McpSessionClaims := {
      sessionId := "s-op", missionId := "", role := "operator", project := "", expiresAt := nowSec + 3600
    }
    let mcpCall (c : McpSessionClaims) (tool : String) (args : JVal) (withSup : Bool := false)
        (askCb? : Option (String → String → String → IO (Except String String)) := none)
        (ansCb? : Option (String → String → String → JVal → IO (Except String (Option String))) := none) : IO JVal := do
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none (some bHub) {} workDir c tool args nowSec
        (remoteSup? := if withSup then some remSup else none) (askSide? := askCb?) (answerQuestion? := ansCb?)
      let .ok jv := OrbBin.Json.parse raw | throw (IO.userError s!"r18 liveness: MCP JSON parse failed for {tool}: {raw}")
      return jv
    let mcpHttpCall (tok : String) (tool : String) (args : JVal) : IO JVal := do
      let body := renderCompact (.obj #[("name", .str tool), ("arguments", args)])
      let (stCode, respBody) ← sendRest app tok "POST" "/api/mcp/call" body (some nowSec)
      check (stCode == 200) s!"POST /api/mcp/call ({tool}) expected 200 (got {stCode}: {respBody})"
      let .ok jv := OrbBin.Json.parse respBody | throw (IO.userError s!"r18 liveness: HTTP MCP JSON parse failed for {tool}: {respBody}")
      return jv

    -- === MCP-03: Canonical fingerprint replays reordered keys and rejects changed value ===
    let u1 ← mcpCall opClaims "update_project_status" (.obj #[
      ("slug", .str "p-mcp03"), ("status", .str "paused"), ("idempotency_key", .str "k-canon-1")
    ])
    check (u1.fieldBool? "ok" == some true) s!"MCP-03 update_project_status succeeded: {renderCompact u1}"
    let u2 ← mcpCall opClaims "update_project_status" (.obj #[
      ("idempotency_key", .str "k-canon-1"), ("status", .str "paused"), ("slug", .str "p-mcp03")
    ])
    check (u2.fieldBool? "ok" == some true && (u2.fieldOrNull "result").fieldStr? "action_id" == (u1.fieldOrNull "result").fieldStr? "action_id")
      s!"MCP-03 reordered-key replay returned identical action_id"
    let u3 ← mcpCall opClaims "update_project_status" (.obj #[
      ("slug", .str "p-mcp03"), ("status", .str "active"), ("idempotency_key", .str "k-canon-1")
    ])
    check ((u3.fieldOrNull "error").fieldStr? "code" == some "conflict")
      s!"MCP-03 changed-value same-key rejected with conflict: {renderCompact u3}"

    -- Keyed import_mission and schedule_job_wakeup settle as succeeded (not uncertain)
    let imp ← mcpCall opClaims "import_mission" (.obj #[
      ("title", .str "Imported"), ("session_id", .str "ses-imp-1"), ("idempotency_key", .str "k-imp-1")
    ])
    check (imp.fieldBool? "ok" == some true) s!"MCP-03 import_mission ok: {renderCompact imp}"
    let impState ← queryCell store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE retry_key='k-imp-1' LIMIT 1;"
    check (impState == "succeeded") s!"MCP-03 import_mission settled succeeded (got {impState})"
    let impMid := (((imp.fieldOrNull "result").fieldOrNull "result").fieldStr? "mission_id")
      |>.orElse (fun _ => (imp.fieldOrNull "result").fieldStr? "mission_id") |>.getD ""
    check (!impMid.isEmpty) s!"MCP-03 import_mission returned mission_id: {renderCompact imp}"
    let jwk ← mcpCall opClaims "schedule_job_wakeup" (.obj #[
      ("mission_id", .str impMid), ("job_id", .str "j-wk-1"), ("prompt", .str "resume"),
      ("idempotency_key", .str "k-jwk-1")
    ])
    check (jwk.fieldBool? "ok" == some true) s!"MCP-03 schedule_job_wakeup ok: {renderCompact jwk}"
    let jwkState ← queryCell store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE retry_key='k-jwk-1' LIMIT 1;"
    check (jwkState == "succeeded") s!"MCP-03 schedule_job_wakeup settled succeeded (got {jwkState})"

    -- write_mission_board rejects conflicting same-key write via MCP
    missionSql store.missionsDb "m-board-c" "active" "local" 1
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET owner_user_id=?1 WHERE id='m-board-c';" #[adminId])
    discard <| require (← execParamQuery store.projectsDb
      "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('s-bd',?1,'m-board-c',?2,0,'mission');"
      #[adminId, s!"{nowSec + 3600}"])
    let bdClaims : McpSessionClaims := { opClaims with sessionId := "s-bd", missionId := "m-board-c", role := "executor" }
    let b1 ← mcpCall bdClaims "write_mission_board" (.obj #[("text", .str "first"), ("idempotency_key", .str "k-bd-1")])
    check (b1.fieldBool? "ok" == some true) "MCP-03 write_mission_board first write ok"
    let b2 ← mcpCall bdClaims "write_mission_board" (.obj #[("text", .str "changed"), ("idempotency_key", .str "k-bd-1")])
    check ((b2.fieldOrNull "error").fieldStr? "code" == some "conflict")
      s!"MCP-03 write_mission_board conflicting key rejected: {renderCompact b2}"

    -- MCP-03: In-flight concurrent duplicate (`state='accepted'`) must return non-terminal `action_in_progress`
    -- with `accepted: "unknown"`, NEVER `ok: true` with `result: {}`!
    let inFlightArgs : JVal := .obj #[("project", .str "p-mcp03"), ("slug", .str "p-mcp03"), ("status", .str "active"), ("idempotency_key", .str "k-inflight-1")]
    let inFlightFp := renderCanonical inFlightArgs
    let inFlightScope := "s-op::update_project_status"
    discard <| require (← execParamQuery store.projectsDb
      ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
       "VALUES('act-inflight-1','',?1,'k-inflight-1',?2,'operator::','update_project_status',?2,'accepted','{}',?3,?3);")
      #[inFlightScope, inFlightFp, nowIso])
    let dupInFlight ← mcpCall opClaims "update_project_status" inFlightArgs
    check (dupInFlight.fieldBool? "ok" == some false &&
           (dupInFlight.fieldOrNull "error").fieldStr? "code" == some "action_in_progress" &&
           (dupInFlight.fieldOrNull "error").fieldStr? "accepted" == some "unknown")
      s!"MCP-03 in-flight duplicate must return action_in_progress/unknown (got {renderCompact dupInFlight})"

    -- MCP-03: Newly wired mutating tool `update_mission_settings` persists receipt with target `owner`, replays identically, conflicts on change
    let ms1 ← mcpHttpCall jwt "update_mission_settings" (.obj #[
      ("mission_id", .str "m-board-c"), ("model_effort", .str "high"), ("idempotency_key", .str "k-ms-1")
    ])
    check (ms1.fieldBool? "ok" == some true) s!"MCP-03 update_mission_settings ok: {renderCompact ms1}"
    let msOwner ← queryCell store.projectsDb "SELECT owner FROM mcp_actions_v1 WHERE retry_key='k-ms-1' LIMIT 1;"
    check (msOwner == "m-board-c") s!"MCP-03 update_mission_settings bound target owner (got {msOwner})"
    let ms2 ← mcpHttpCall jwt "update_mission_settings" (.obj #[
      ("idempotency_key", .str "k-ms-1"), ("model_effort", .str "high"), ("mission_id", .str "m-board-c")
    ])
    check (ms2.fieldBool? "ok" == some true && (ms2.fieldOrNull "result").fieldStr? "action_id" == (ms1.fieldOrNull "result").fieldStr? "action_id")
      s!"MCP-03 update_mission_settings replayed identically"
    let ms3 ← mcpHttpCall jwt "update_mission_settings" (.obj #[
      ("mission_id", .str "m-board-c"), ("model_effort", .str "low"), ("idempotency_key", .str "k-ms-1")
    ])
    check ((ms3.fieldOrNull "error").fieldStr? "code" == some "conflict")
      s!"MCP-03 update_mission_settings conflict rejected: {renderCompact ms3}"

    -- MCP-03: Ambiguous managed lifecycle failure settles as `uncertain` (`accepted: "unknown"`), NOT `failed`!
    let .ok mcUnc ← openManagedComputeStore s!"{workDir}/managed_unc.db" (some store.missionsDb)
      | throw (IO.userError "MCP-03 open managed store failed")
    try
      let uncFleet : ManagedFleetState :=
        { enabled := true, boatEnabled := true, dailyCapCents := 5000, spentTodayCents := 0, maxConcurrent := 10 }
      discard <| require (← saveManagedFleetConfig mcUnc true true 5000 0 10)
      let uncVm : ManagedMachine :=
        { id := "vm-unc-1", sandboxName := "orb-managed-vm-unc-1", provider := "boat", size := "small",
          ownerMission := "m-board-c", ttlMinutes := 60, spentCents := 1 }
      discard <| require (← provisionManagedMachine mcUnc uncFleet uncVm nowSec)
      discard <| require (← execParamQuery mcUnc.db
        "UPDATE managed_machines SET phase_code=1, status='running', provider_id='prov-unc-1' WHERE id='vm-unc-1';" #[])
      let uncProv : ManagedProvider.Provider := {
        name := "boat"
        readinessDeadlineSecs := 60
        isReady := fun s => s == "running"
        isStopped := fun s => s == "stopped"
        quoteCents := fun _ _ => .ok 1
        spawn := fun _ => pure (.error { status := 504, code := "provider_http_error" })
        get := fun id => pure (.ok { providerId := id, state := "running" })
        list := pure (.ok #[])
        destroy := fun _ => pure (.error { status := 504, code := "provider_http_error" })
        stop := fun _ => pure (.error { status := 504, code := "provider_http_error" })
        resume := fun _ _ => pure (.error { status := 504, code := "provider_http_error" })
        fork := fun _ _ => pure (.error { status := 504, code := "provider_http_error" })
        extend := fun _ _ => pure (.error { status := 504, code := "provider_http_error" })
        saveSnapshot := fun _ _ => pure (.ok ())
        getSnapshot := fun n => pure (.ok { name := n, status := "ready" })
        listSnapshots := pure (.ok #[])
        deleteSnapshot := fun _ => pure (.ok ())
        writeFile := fun _ _ _ => pure (.ok ())
        exec := fun _ _ _ => pure (.ok (.obj #[]))
        supportsStopResume := pure true
      }
      let uncOverride : ManagedProvider.Provider × ManagedProvisioning.BootstrapConfig :=
        (uncProv, { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" })
      let uncRaw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mcUnc) none none uncFleet workDir opClaims
        "stop_managed_machine" (.obj #[("machine_id", .str "vm-unc-1"), ("idempotency_key", .str "k-stop-unc-1")])
        nowSec none (some uncOverride) "" true
      let uncJv := (OrbBin.Json.parse uncRaw).toOption.getD (.obj #[])
      let uncState ← queryCell store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE retry_key='k-stop-unc-1' LIMIT 1;"
      check (uncJv.fieldBool? "ok" == some false &&
             (uncJv.fieldOrNull "error").fieldStr? "accepted" == some "unknown" &&
             uncState == "uncertain")
        s!"MCP-03 ambiguous managed lifecycle error must settle uncertain/unknown (state={uncState} resp={uncRaw})"
      -- Replaying the same idempotency_key returns uncertain/unknown without re-executing!
      let uncReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mcUnc) none none uncFleet workDir opClaims
        "stop_managed_machine" (.obj #[("machine_id", .str "vm-unc-1"), ("idempotency_key", .str "k-stop-unc-1")])
        nowSec none (some uncOverride) "" true
      let uncReplayJv := (OrbBin.Json.parse uncReplayRaw).toOption.getD (.obj #[])
      check (uncReplayJv.fieldBool? "ok" == some false &&
             (uncReplayJv.fieldOrNull "error").fieldStr? "accepted" == some "unknown")
        s!"MCP-03 replay of uncertain managed lifecycle must preserve accepted=unknown (resp={uncReplayRaw})"
    finally closeManagedComputeStore mcUnc

    -- === MCP-07: Real end-to-end `POST /api/mcp/call` `answer_mission_question` through `Control.lean` ===
    missionSql store.missionsDb "m-qna" "active" "local" 1
    discard <| require (← execParamQuery store.missionsDb "UPDATE missions SET owner_user_id=?1 WHERE id='m-qna';" #[adminId])
    let capturedStdin := s!"{workDir}/claude_stdin.log"
    let mockClaude := s!"{workDir}/mock_claude.sh"
    IO.FS.writeFile mockClaude
      ("#!/bin/sh\n" ++
       "read -r _init\n" ++
       "read -r _user\n" ++
       "printf '%s\\n' '{\"type\":\"control_request\",\"request_id\":\"req-qna-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Pick one?\",\"header\":\"Choice\"}]}}}'\n" ++
       s!"read -r resp\nprintf '%s\\n' \"$resp\" > '{capturedStdin}'\n" ++
       "printf '%s\\n' '{\"type\":\"result\",\"result\":\"answered\",\"num_turns\":1,\"is_error\":false}'\n")
    discard <| IO.Process.output { cmd := "/bin/chmod", args := #["+x", mockClaude] }
    let .ok _ ← startHarnessTurn mgr "m-qna" "claudecode" mockClaude workDir "ask me" 1 none none none .supervised "local"
      | throw (IO.userError "MCP-07 start mock warm claude failed")
    let mut hasPending := false
    for _ in [:40] do
      if !(← pendingControlRequestsFor mgr "m-qna").isEmpty then hasPending := true; break
      IO.sleep 30
    check hasPending "MCP-07 mock warm claude surfaced pending AskUserQuestion"

    -- 1. Structured string[][] + omitted tool_call_id through REAL `POST /api/mcp/call`
    let ansOk ← mcpHttpCall jwt "answer_mission_question" (.obj #[
      ("mission_id", .str "m-qna"), ("answers", .arr #[.arr #[.str "Option B"]]), ("idempotency_key", .str "k-ans-1")
    ])
    let resolvedTid := ((ansOk.fieldOrNull "result").fieldStr? "tool_call_id").getD ""
    check (ansOk.fieldBool? "ok" == some true && resolvedTid == "req-qna-1")
      s!"MCP-07 real /api/mcp/call auto-selected and recorded tool_call_id=req-qna-1 (got {renderCompact ansOk})"
    let mut wireWritten := ""
    for _ in [:40] do
      if (← System.FilePath.pathExists capturedStdin) then
        let txt ← IO.FS.readFile capturedStdin
        if !txt.trimAscii.toString.isEmpty then wireWritten := txt; break
      IO.sleep 30
    check (wireWritten.contains "\"control_response\"" && wireWritten.contains "\"Pick one?\":\"Option B\"")
      s!"MCP-07 translated string[][] to Claude question-keyed map (got {wireWritten})"
    let trCnt ← count store.missionsDb "SELECT COUNT(*) FROM mission_events WHERE mission_id='m-qna' AND event_type='tool_result';"
    check (trCnt >= 1) "MCP-07 persisted tool_result event"
    -- 0 pending on local mission -> failed/not_found (not uncertain), scalar answers -> invalid_arguments
    let ansMiss ← mcpHttpCall jwt "answer_mission_question" (.obj #[
      ("mission_id", .str "m-qna"), ("answers", .arr #[.arr #[.str "Late"]]), ("idempotency_key", .str "k-ans-miss")
    ])
    check ((ansMiss.fieldOrNull "error").fieldStr? "code" == some "not_found") "MCP-07 missing question returns not_found"
    let missState ← queryCell store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE retry_key='k-ans-miss' LIMIT 1;"
    let missOwner ← queryCell store.projectsDb "SELECT owner FROM mcp_actions_v1 WHERE retry_key='k-ans-miss' LIMIT 1;"
    check (missState == "failed" && missOwner == "m-qna")
      s!"MCP-07 missing question settled failed with target owner m-qna (state={missState} owner={missOwner})"
    let ansBad ← mcpHttpCall jwt "answer_mission_question" (.obj #[
      ("mission_id", .str "m-qna"), ("answers", .str "scalar"), ("idempotency_key", .str "k-ans-bad")
    ])
    check ((ansBad.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments") "MCP-07 scalar answers rejected"
    stopHarnessRun mgr "m-qna"

    -- 2. Real `NativeGoalApproval` ticket via SCOPED MCP session token + `[["reject"]]` + omitted `tool_call_id`
    missionSql store.missionsDb "m-nga" "active" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, goal_mode=1, placement_job_id='job-nga-1', tags='[\"remote-node:node-a\"]' WHERE id='m-nga';" #[adminId])
    discard <| require (← execParamQuery store.missionsDb
      ("CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', " ++
       "node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
       "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');") #[])
    discard <| require (← execParamQuery store.missionsDb
      "INSERT OR REPLACE INTO remote_node_jobs(job_id,mission_id,node_id,state,payload_json,created_at,updated_at) VALUES('job-nga-1','m-nga','node-a','running','{}',?1,?1);" #[nowIso])
    let ngaTicket := OrbCore.NativeGoalApproval.ticketPrefix ++ "r18-ticket-1"
    discard <| require (← execParamQuery store.missionsDb
      "INSERT INTO native_goal_approvals(id,mission,owner,job,input_digest,expires,decision) VALUES(?1,'m-nga',?2,'job-nga-1','dig',CAST(?3 AS INTEGER),'pending');"
      #[ngaTicket, adminId, s!"{nowSec + 120}"])
    -- Mint a scoped MCP session token (so `mcpCaller? == none` in Control.lean, testing scoped ownerUid!)
    let (sessSt, sessBody) ← sendRest app jwt "POST" "/api/mcp/session"
      "{\"mission_id\":\"m-nga\",\"role\":\"operator\"}" (some nowSec)
    check (sessSt == 200) s!"MCP-07 mint scoped MCP session failed ({sessSt}: {sessBody})"
    let scopedTok := ((OrbBin.Json.parse sessBody).toOption.bind (·.fieldStr? "token")).getD ""
    check (!scopedTok.isEmpty) "MCP-07 scoped MCP token non-empty"
    -- Unrecognized action must be rejected (never silently defaulted to accept!)
    let ngaBogus ← mcpHttpCall scopedTok "answer_mission_question" (.obj #[
      ("mission_id", .str "m-nga"), ("answers", .arr #[.arr #[.str "maybe"]]), ("idempotency_key", .str "k-nga-bad")
    ])
    check ((ngaBogus.fieldOrNull "error").fieldStr? "code" == some "invalid_arguments")
      s!"MCP-07 unrecognized NativeGoalApproval action must fail invalid_arguments (got {renderCompact ngaBogus})"
    let decStillPending ← queryCell store.missionsDb "SELECT decision FROM native_goal_approvals WHERE id=?1;" #[ngaTicket]
    check (decStillPending == "pending") s!"MCP-07 bogus action left ticket pending (got {decStillPending})"
    -- Schema-standard `[["reject"]]` with omitted `tool_call_id` must DECLINE the ticket and record resolved `tool_call_id`!
    let ngaRej ← mcpHttpCall scopedTok "answer_mission_question" (.obj #[
      ("mission_id", .str "m-nga"), ("answers", .arr #[.arr #[.str "reject"]]), ("idempotency_key", .str "k-nga-rej")
    ])
    let ngaTid := ((ngaRej.fieldOrNull "result").fieldStr? "tool_call_id").getD ""
    let decAfterRej ← queryCell store.missionsDb "SELECT decision FROM native_goal_approvals WHERE id=?1;" #[ngaTicket]
    check (ngaRej.fieldBool? "ok" == some true && ngaTid == ngaTicket && decAfterRej == "declined")
      s!"MCP-07 [['reject']] declined NativeGoalApproval via scoped MCP session (resp={renderCompact ngaRej} dec={decAfterRej})"
    -- Remote mission with 0 pending approval/local questions returns `unsupported`
    let ngaUnsup ← mcpHttpCall scopedTok "answer_mission_question" (.obj #[
      ("mission_id", .str "m-nga"), ("answers", .arr #[.arr #[.str "ok"]]), ("idempotency_key", .str "k-nga-unsup")
    ])
    check ((ngaUnsup.fieldOrNull "error").fieldStr? "code" == some "unsupported")
      s!"MCP-07 remote mission with no pending local/approval channel returns unsupported (got {renderCompact ngaUnsup})"

    -- ask_mission: accepts null thread_id, rejects non-empty thread_id
    let fakeAsk : String → String → String → IO (Except String String) := fun _ _ _ =>
      pure (.ok "{\"id\":\"m-side-1\",\"status\":\"active\"}")
    let askNull ← mcpCall opClaims "ask_mission" (.obj #[
      ("mission_id", .str "m-qna"), ("content", .str "status?"), ("thread_id", .null), ("idempotency_key", .str "k-ask-1")
    ]) false (some fakeAsk) none
    check (askNull.fieldBool? "ok" == some true) s!"MCP-07 ask_mission accepted null thread_id: {renderCompact askNull}"
    let askThr ← mcpCall opClaims "ask_mission" (.obj #[
      ("mission_id", .str "m-qna"), ("content", .str "status?"), ("thread_id", .str "t-1"), ("idempotency_key", .str "k-ask-2")
    ]) false (some fakeAsk) none
    check ((askThr.fieldOrNull "error").fieldStr? "code" == some "unsupported_argument") "MCP-07 ask_mission rejected non-empty thread_id"

    -- send_message_to_mission with remoteSup?: rejects unsupported mode/fields & local missions, queues active remote
    let smMode ← mcpCall opClaims "send_message_to_mission" (.obj #[
      ("mission_id", .str "m-qna"), ("message", .str "hi"), ("mode", .str "steer")
    ]) true
    check ((smMode.fieldOrNull "error").fieldStr? "code" == some "unsupported") "MCP-07 send_message rejected steer mode"
    let smLocal ← mcpCall opClaims "send_message_to_mission" (.obj #[
      ("mission_id", .str "m-qna"), ("message", .str "hi")
    ]) true
    check ((smLocal.fieldOrNull "error").fieldStr? "code" == some "unsupported") "MCP-07 send_message failed closed on local mission"
    missionSql store.missionsDb "m-rem-sm" "active" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, tags='[\"remote-node:node-a\"]' WHERE id='m-rem-sm';" #[adminId])
    let smQ ← mcpCall opClaims "send_message_to_mission" (.obj #[
      ("mission_id", .str "m-rem-sm"), ("message", .str "follow up"), ("idempotency_key", .str "k-sm-1")
    ]) true
    check (smQ.fieldBool? "ok" == some true && (smQ.fieldOrNull "result").fieldBool? "queued" == some true)
      s!"MCP-07 send_message queued on active remote mission: {renderCompact smQ}"

    -- === FUP-01 & FUP-02: Queue cancellation + job-bound protection + collision-free send-now ===
    missionSql store.missionsDb "m-fup-a" "active" "remote" 1
    missionSql store.missionsDb "m-fup-b" "active" "remote" 1
    missionSql store.missionsDb "m-fup-arch" "acknowledged" "remote" 1
    discard <| require (← execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?1, tags='[\"remote-node:node-a\"]' WHERE id IN ('m-fup-a','m-fup-b','m-fup-arch');" #[adminId])
    -- Deliberately occupy sequence=9 (mission B) and sequence=10 (delivered) right below mission A's waiting rows
    discard <| require (← execParamQuery store.missionsDb
      ("INSERT INTO remote_message_queue(sequence,user_id,message_id,mission_id,payload,state,phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision) VALUES " ++
       "(9,'core','q-fup-other','m-fup-b','{\"content\":\"other\",\"mission_id\":\"m-fup-b\"}','waiting',0,0,0,0,0)," ++
       "(10,'core','q-fup-deliv','m-fup-a','{\"content\":\"done\",\"mission_id\":\"m-fup-a\"}','delivered',2,0,0,1,0)," ++
       "(11,'core','q-fup-job','m-fup-a','{\"job_id\":\"j-bound\",\"content\":\"bound\",\"mission_id\":\"m-fup-a\"}','waiting',0,0,0,0,0)," ++
       "(12,'core','q-fup-w1','m-fup-a','{\"content\":\"first\",\"mission_id\":\"m-fup-a\"}','waiting',0,0,0,0,0)," ++
       "(13,'core','q-fup-w2','m-fup-a','{\"content\":\"second\",\"mission_id\":\"m-fup-a\"}','waiting',0,0,0,0,0)," ++
       "(14,'core','q-fup-arch','m-fup-arch','{\"content\":\"old\",\"mission_id\":\"m-fup-arch\"}','waiting',0,0,0,0,0);") #[])

    -- FUP-02: send-now promotes q-fup-w2 ahead of q-fup-w1 without UNIQUE collision on sequence=9/10
    let (snSt, snBody) ← sendRest app jwt "POST" "/api/control/queue/q-fup-w2/send-now" "" (some nowSec)
    check (snSt == 200 && snBody.contains "\"promoted\":true" && snBody.contains "\"mission_id\":\"m-fup-a\"")
      s!"FUP-02 collision-free send-now failed: {snSt} {snBody}"
    let w2Seq ← count store.missionsDb "SELECT sequence FROM remote_message_queue WHERE message_id='q-fup-w2';"
    let w1Seq ← count store.missionsDb "SELECT sequence FROM remote_message_queue WHERE message_id='q-fup-w1';"
    check (w2Seq < w1Seq) s!"FUP-02 promoted q-fup-w2 ({w2Seq}) ahead of q-fup-w1 ({w1Seq})"
    -- Job-bound send-now -> 409
    let (jbSnSt, _) ← sendRest app jwt "POST" "/api/control/queue/q-fup-job/send-now" "" (some nowSec)
    check (jbSnSt == 409) s!"FUP-02 job-bound send-now expected 409 (got {jbSnSt})"
    -- Acknowledged mission send-now -> 200 promoted:false
    let (arSnSt, arSnBody) ← sendRest app jwt "POST" "/api/control/queue/q-fup-arch/send-now" "" (some nowSec)
    check (arSnSt == 200 && arSnBody.contains "\"promoted\":false")
      s!"FUP-02 acknowledged mission send-now expected promoted:false (got {arSnSt}: {arSnBody})"
    -- interrupt=true without remoteSup? -> 503
    let (noSupSt, _) ← sendRest { app with remoteSup? := none } jwt "POST" "/api/control/queue/q-fup-w1/send-now?interrupt=true" "" (some nowSec)
    check (noSupSt == 503) s!"FUP-02 interrupt=true without remoteSup? expected 503 (got {noSupSt})"

    -- FUP-01: item DELETE on job-bound -> 409; collection DELETE cancels waiting rows only, preserving delivered/job-bound/other-mission
    let (jbDelSt, _) ← sendRest app jwt "DELETE" "/api/control/queue/q-fup-job" "" (some nowSec)
    check (jbDelSt == 409) s!"FUP-01 item DELETE on job-bound expected 409 (got {jbDelSt})"
    let (colDelSt, _) ← sendRest app jwt "DELETE" "/api/control/queue?mission_id=m-fup-a" "" (some nowSec)
    check (colDelSt == 200) s!"FUP-01 collection DELETE failed ({colDelSt})"
    let wRem ← count store.missionsDb
      "SELECT COUNT(*) FROM remote_message_queue WHERE message_id IN ('q-fup-w1','q-fup-w2') AND phase=0;"
    let keptDeliv ← count store.missionsDb
      "SELECT COUNT(*) FROM remote_message_queue WHERE message_id='q-fup-deliv' AND phase=2;"
    let keptJob ← count store.missionsDb
      "SELECT COUNT(*) FROM remote_message_queue WHERE message_id='q-fup-job' AND phase=0;"
    let keptOther ← count store.missionsDb
      "SELECT COUNT(*) FROM remote_message_queue WHERE message_id='q-fup-other' AND phase=0;"
    check (wRem == 0 && keptDeliv == 1 && keptJob == 1 && keptOther == 1)
      s!"FUP-01 collection DELETE invariant failed (wRem={wRem} deliv={keptDeliv} job={keptJob} other={keptOther})"
  finally
    closeCoreStore store
    discard <| (IO.FS.removeDirAll workDir).toBaseIO

/-- Run the complete R18 runtime liveness deterministic test suite across all 16 items. -/
def runAll (root : String) : IO Unit := do
  recoveryAndOrphanReaping s!"{root}/r18-recovery"
  lineageMissionBudget s!"{root}/r18-lineage"
  testRemoteFaultsAndFollowupPump s!"{root}/r18-remote"
  testLocalSupervisionAndScopes s!"{root}/r18-local"
  testLiveSseAndWebSocketTransports s!"{root}/r18-transports"
  testContinuationsAndTelemetry s!"{root}/r18-cont-telem"
  testMcpAndQueueContracts s!"{root}/r18-mcp-queue"
  IO.println "[PASS] R18LivenessTests: all 16 R18 runtime liveness checks passed"

end OrbCore.R18LivenessTests
