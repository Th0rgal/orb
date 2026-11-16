/-
  A turn that ends with no output is a failure, retried a bounded number of
  times and then `failed`; a mission whose first turn cannot be dispatched is
  not created `active`. No harness, node or network is used.
-/
import OrbCore.Control

namespace OrbCore.TurnOutcomeTests
open OrbBin.Json OrbBin.Sqlite OrbBin.PosixExt
open OrbCore.Store OrbCore.Control OrbCore.R7Core OrbCore.Proxy OrbCore.Managed
open OrbCore.RemoteDispatch OrbCore.MemoryAndCloud

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"turn outcome: {label}")

private def stateTagOf (s : String) : UInt8 :=
  match s.trimAscii.toString.toLower with
  | "" | "queued" | "pending" | "accepted" => 0
  | "running" | "dispatching" | "in_progress" => 1
  | "completed" | "succeeded" | "settled" => 2
  | "failed" | "rejected" | "cancelled" | "canceled" => 3
  | "reconciliation_required" | "uncertain" => 4
  | _ => 5

private def acceptedTagOf (receipt : JVal) : UInt8 :=
  let v := (receipt.field? "accepted").orElse (fun _ => (receipt.fieldOrNull "error").field? "accepted") |>.getD .null
  match v with
  | .null => 0
  | .bool true => 1
  | .bool false => 2
  | .str s =>
    match s.trimAscii.toString.toLower with
    | "yes" | "true" => 1
    | "no" | "false" => 2
    | "unknown" => 3
    | _ => 4
  | _ => 4

private def verifyReceiptWord (receipt : JVal) (transportDropped : Bool := false) : UInt32 :=
  let stateRaw := ((receipt.fieldStr? "state").orElse (fun _ => receipt.fieldStr? "status")).getD ""
  let statusRaw := ((receipt.fieldStr? "status").orElse (fun _ => receipt.fieldStr? "state")).getD ""
  let stTag := stateTagOf stateRaw
  let hasErr := match receipt.field? "error" with | some .null | none => false | some _ => true
  let hasRes : UInt8 := match receipt.field? "result" with | some .null | none => 0 | some _ => if hasErr then 0 else 1
  let accTag := acceptedTagOf receipt
  let base := stateTagOf statusRaw
  let rsTag : UInt8 :=
    if base == 0 && statusRaw.isEmpty then
      if accTag == 3 then 4 else if hasErr || accTag == 2 then 3 else if hasRes == 1 then 2 else 0
    else if base == 2 && hasErr then 3 else base
  let stClean : UInt8 := if stTag ≤ 4 then stTag else 3
  OrbBin.Spec.verifyMcpActionOutcome rsTag accTag stClean (if transportDropped then 1 else 0) hasRes

private def cellOf (db : SqliteDb) (sql : String) (params : Array String := #[]) : IO String := do
  let .ok rows ← execParamQuery db sql params | throw (IO.userError s!"query failed: {sql}")
  return (rows[1]?.bind (·[0]?)).getD ""

def r24_lost_reply_is_uncertain_not_rejected : IO Unit := do
  let receipt := JVal.obj #[
    ("action_id", .str "r24-lost"), ("state", .str "uncertain"),
    ("status", .str "uncertain"), ("accepted", .str "unknown"),
    ("error", .str "transport_unavailable")]
  check (verifyReceiptWord receipt true == 259 && receipt.fieldStr? "accepted" == some "unknown") "lost reply is uncertain"

def r24_failed_enqueue_is_not_success : IO Unit := do
  let receipt := JVal.obj #[("state", .str "failed"), ("status", .str "failed"), ("accepted", .str "no"), ("error", .str "enqueue_failed")]
  check (verifyReceiptWord receipt == 16777474) "failed enqueue is rejected"

def r24_failed_dispatch_is_not_success : IO Unit := do
  let receipt := JVal.obj #[("state", .str "failed"), ("status", .str "failed"), ("accepted", .str "no"), ("error", .str "remote_dispatch_failed")]
  check (verifyReceiptWord receipt == 16777474) "failed dispatch is rejected"

def r24_failed_cancel_is_not_success : IO Unit := do
  let receipt := JVal.obj #[("state", .str "failed"), ("status", .str "failed"), ("accepted", .str "no"), ("error", .str "cancel_failed")]
  check (verifyReceiptWord receipt == 16777474) "failed cancel is rejected"

def r24_cancel_without_remote_job_is_success (receipt : JVal) : IO Unit := do
  check (verifyReceiptWord receipt == 65793 &&
    (receipt.fieldOrNull "result").fieldStr? "status" == some "cancelled")
    "local cancellation succeeds when no remote job exists"

def r24_concurrent_same_key_mutates_once (store : CoreStore) (root : String) (claims : McpSessionClaims) : IO Unit := do
  let args := .obj #[("mission_id", .str "m-tools"), ("content", .str "r24 concurrent"), ("idempotency_key", .str "r24-concurrent-key")]
  let t1 ← IO.asTask (OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "send_message_to_mission" args 4000000000)
  let t2 ← IO.asTask (OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "send_message_to_mission" args 4000000000)
  let a := match t1.get with | .ok x => x | .error _ => ""
  let b := match t2.get with | .ok x => x | .error _ => ""
  let aid x := (((OrbBin.Json.parse x).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
  check (aid a == aid b && aid a != "") "same-key callers share one stored receipt"
  check ((← cellOf store.askDb "SELECT COUNT(*) FROM operator_notes WHERE content='r24 concurrent';") == "1")
    "same-key concurrent callers insert exactly one note"

def r24_receipt_insert_failure_blocks_mutation (store : CoreStore) (root : String) (claims : McpSessionClaims) : IO Unit := do
  let args := .obj #[("mission_id", .str "m-tools"), ("content", .str "r24 reservation"), ("idempotency_key", .str "r24-reservation-key")]
  let .ok _ ← execParamQuery store.projectsDb
      "CREATE TRIGGER r24_deny_reservation BEFORE INSERT ON mcp_actions_v1 BEGIN SELECT RAISE(ABORT,'injected reservation failure'); END;" #[]
    | throw (IO.userError "reservation failure trigger failed")
  try
    let raw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "send_message_to_mission" args 4000000000
    check ((raw.splitOn "receipt_reservation_failed").length > 1) "reservation failure is reported"
    check ((← cellOf store.askDb "SELECT COUNT(*) FROM operator_notes WHERE content='r24 reservation';") == "0")
      "failed reservation prevents note mutation"
  finally
    let .ok _ ← execParamQuery store.projectsDb "DROP TRIGGER r24_deny_reservation;" #[]
      | throw (IO.userError "reservation failure trigger cleanup failed")

def r24_same_key_retry_returns_stored_receipt (store : CoreStore) (root : String) (claims : McpSessionClaims) : IO Unit := do
  let args := .obj #[("mission_id", .str "m-tools"), ("content", .str "r24 replay"), ("idempotency_key", .str "r24-replay-key")]
  let first ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "send_message_to_mission" args 4000000000
  let second ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "send_message_to_mission" args 4000000000
  let aid x := (((OrbBin.Json.parse x).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
  check (aid first == aid second && aid first != "") "same-key retry returns stored receipt"
  check ((← cellOf store.askDb "SELECT COUNT(*) FROM operator_notes WHERE content='r24 replay';") == "1")
    "replay does not insert another note"

def r24_failed_remote_cancel_survives_ledger_rewrite (store : CoreStore) (root : String) (claims : McpSessionClaims) : IO Unit := do
  let .ok _ ← execParamQuery store.missionsDb
      "CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');" #[]
    | throw (IO.userError "cancel table fixture failed")
  let .ok _ ← execParamQuery store.missionsDb
      "INSERT INTO remote_node_jobs(job_id,mission_id,node_id,state) VALUES('r24-cancel-job','m-tools','','running');" #[]
    | throw (IO.userError "cancel job fixture failed")
  let args := JVal.obj #[("mission_id", .str "m-tools"), ("idempotency_key", .str "r24-cancel-failed")]
  discard <| OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "cancel_mission" args 4000000000
  check ((← cellOf store.missionsDb "SELECT state FROM remote_node_jobs WHERE job_id='r24-cancel-job';") == "cancelled")
    "helper rewrites ledger despite missing node"
  check ((← cellOf store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE retry_key='r24-cancel-failed';") == "uncertain")
    "failed cancellation remains uncertain after ledger rewrite"
  let replay ← OrbCore.McpGateway.dispatchMcpToolCall store none none none {} root claims "cancel_mission" args 4000000000
  let receipt := ((OrbBin.Json.parse replay).toOption.getD .null).fieldOrNull "result"
  check (receipt.fieldStr? "state" == some "uncertain" && receipt.fieldStr? "accepted" == some "unknown")
    "retry preserves unknown remote cancellation outcome"
  check ((← cellOf store.missionsDb "SELECT status FROM missions WHERE id='m-tools';") != "cancelled")
    "failed remote cancellation does not claim mission termination"

def r24_startup_fences_spawn_only (store : CoreStore) : IO Unit := do
  let .ok _ ← execParamQuery store.projectsDb
      ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
       "VALUES('r24-fence','m-tools','r24-fence-scope','r24-fence-key','{}','coordinator','spawn_managed_machine','{}','accepted','{}','t0','t0');") #[]
    | throw (IO.userError "fence fixture insert failed")
  let .ok _ ← OrbCore.ManagedSpawnActions.fenceInterrupted store | throw (IO.userError "fence failed")
  check ((← cellOf store.projectsDb "SELECT state FROM mcp_actions_v1 WHERE id='r24-fence';") == "uncertain") "startup fences generic accepted action"

def run : IO Unit := do
  r24_lost_reply_is_uncertain_not_rejected
  r24_failed_enqueue_is_not_success
  r24_failed_dispatch_is_not_success
  r24_failed_cancel_is_not_success
  let root := s!"/tmp/orb-turn-outcome-{← newUuidV4}"
  IO.FS.createDirAll s!"{root}/.sandboxed-sh"
  try
    let .ok store ← openCoreStore s!"{root}/.sandboxed-sh" | throw (IO.userError "turn outcome store open failed")
    try
      let cfg : CoreConfig := {
        workingDir := root
        dashboardPassword := "turn-outcome-fixture-password"
        jwtSecret := "turn-outcome-fixture-jwt-secret-0123456789"
      }
      let app : CoreAppState := {
        cfg := cfg, store := store, searchIdx? := none,
        managedRef := (← IO.mkRef ({} : ManagedFleetState)), chainsRef := (← IO.mkRef (#[] : Array RoutingChain)),
        proxyCooldownsRef := (← IO.mkRef (#[] : Array AccountCooldown)), seqRef := (← IO.mkRef (1 : UInt64))
      }
      let db := store.missionsDb
      let newMission := fun (mid tags : String) => do
        let .ok _ ← execParamQuery db
            ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,node_boot_epoch,created_at,updated_at) " ++
             "VALUES(?1,'turn','active','claudecode','','','managed',?2,1,1,'t0','t0');") #[mid, tags]
          | throw (IO.userError "turn outcome mission insert failed")
        discard <| appendMissionEvent store mid "user_message" "{\"content\":\"do the task\"}" "t0"
      -- What every local harness reports when it exits 0 having said and done nothing.
      let finishEmpty := fun (mid : String) =>
        (buildCoreHarnessCallbacks app mid).onTurnFinished
          { runId := "r", generation := 1, harness := "claudecode", cwd := root, done := true, exitCode? := some 0 }
      let statusOf := fun (mid : String) => cellOf db "SELECT status FROM missions WHERE id=?1;" #[mid]
      let retries := fun (mid : String) =>
        cellOf db "SELECT COALESCE(group_concat(reason || '/' || phase, ','),'') FROM (SELECT reason,phase FROM mission_continuations WHERE mission_id=?1 ORDER BY rowid);" #[mid]
      let emptyErrors := fun (mid : String) =>
        cellOf db "SELECT COUNT(*) FROM mission_events WHERE mission_id=?1 AND event_type='error' AND payload LIKE '%empty_turn%';" #[mid]

      newMission "m-empty" "[]"
      finishEmpty "m-empty"
      check ((← retries "m-empty") == "empty_turn_retry:1/1") s!"an empty turn arms one retry, got '{← retries "m-empty"}'"
      check ((← statusOf "m-empty") == "awaiting_user" && (← emptyErrors "m-empty") == "1") "the empty turn is reported as an error"

      -- The durable scheduler relaunches it; each relaunch that is empty again counts.
      let sup ← newRemoteJobSupervisor "turn-outcome-fixture-secret" false
      let launches ← IO.mkRef (0 : Nat)
      let prompts ← IO.mkRef (#[] : Array String)
      let launch : MissionRecord → String → Option String → IO Bool := fun mr prompt _ => do
        launches.modify (· + 1)
        prompts.modify (·.push prompt)
        discard <| execParamQuery db "UPDATE missions SET status='active' WHERE id=?1;" #[mr.id]
        return true
      let tick := fun (now : UInt64) =>
        discard <| tickContinuationScheduler store none none none sup none root (some launch) (some now)
      tick 4000000000
      check ((← launches.get) == 1 && (← statusOf "m-empty") == "active") "the retry relaunches the turn"
      -- The retry is a NEW user turn for every backend: the conversation the harness
      -- resumes never ends on the empty assistant message (vendors reject that).
      check ((← prompts.get).all (fun p => (p.splitOn "ended without any output").length == 2))
        s!"the retry delivers a continuation prompt: {← prompts.get}"
      check ((← cellOf db "SELECT event_type || ':' || (instr(payload,'ended without any output')>0) FROM mission_events WHERE mission_id='m-empty' ORDER BY id DESC LIMIT 1;") == "user_message:1")
        "the retry is recorded as a user message after the empty turn"
      finishEmpty "m-empty"
      check ((← retries "m-empty") == "empty_turn_retry:1/4,empty_turn_retry:2/1") s!"second empty turn, got '{← retries "m-empty"}'"
      tick 4000000100
      finishEmpty "m-empty"
      check ((← launches.get) == 2 && (← statusOf "m-empty") == "failed")
        s!"after the bounded retries the mission is failed, got {← statusOf "m-empty"}"
      check ((← retries "m-empty") == "empty_turn_retry:1/4,empty_turn_retry:2/4") "no third retry is armed"
      tick 4000000200
      check ((← launches.get) == 2) "a failed mission is not relaunched"

      -- A new instruction from the user starts a fresh count.
      discard <| execParamQuery db "UPDATE missions SET status='active' WHERE id='m-empty';" #[]
      discard <| appendMissionEvent store "m-empty" "user_message" "{\"content\":\"try again\"}" "t1"
      finishEmpty "m-empty"
      check ((← statusOf "m-empty") == "awaiting_user" && ((← retries "m-empty").splitOn "empty_turn_retry:1/1").length == 2)
        "a new user message resets the retry count"

      -- A turn that only called tools did work: not empty.
      newMission "m-tools" "[]"
      discard <| appendMissionEvent store "m-tools" "tool_call" "{\"tool_name\":\"Bash\"}" "t0"
      finishEmpty "m-tools"
      check ((← statusOf "m-tools") == "awaiting_user" && (← retries "m-tools").isEmpty && (← emptyErrors "m-tools") == "0")
        "a tool-only turn is not an empty turn"

      -- A side question is answered once: empty means failed, never completed.
      newMission "m-side" "[\"side-question\"]"
      finishEmpty "m-side"
      check ((← statusOf "m-side") == "failed" && (← retries "m-side").isEmpty) s!"empty side question, got {← statusOf "m-side"}"

      -- A first turn with nowhere to run is refused; nothing is left `active`.
      let claims : McpSessionClaims := { sessionId := "turn-outcome", missionId := "m-tools", role := "coordinator", expiresAt := 4100000000 }
      r24_concurrent_same_key_mutates_once store root claims
      r24_receipt_insert_failure_blocks_mutation store root claims
      r24_same_key_retry_returns_stored_receipt store root claims
      r24_failed_remote_cancel_survives_ledger_rewrite store root claims
      r24_startup_fences_spawn_only store
      let reply ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "start_mission" (.obj #[("title", .str "ghost"), ("prompt", .str "work that can never start")]) 4000000000
      check ((reply.splitOn "no_execution_placement").length > 1) s!"an undispatchable start is refused: {reply}"
      check ((← cellOf db "SELECT COUNT(*) FROM missions WHERE title='ghost';") == "0") "no ghost mission is left behind"

      -- Receipts name the model asked for and the model the turn is launched with;
      -- afterwards the mission reports which model and provider actually answered.
      let receipt ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "start_mission" (.obj #[("title", .str "receipt"), ("backend", .str "opencode"), ("idempotency_key", .str "start-receipt-1")]) 4000000000
      let receiptReplay ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "start_mission" (.obj #[("title", .str "receipt"), ("backend", .str "opencode"), ("idempotency_key", .str "start-receipt-1")]) 4000000000
      -- Tool results may carry their JSON as an escaped string: compare without the escapes.
      let flat := fun (raw : String) => raw.replace "\\" ""
      check (((flat receipt).splitOn "\"effective_model\":\"builtin/smart\"").length >= 2)
        s!"an opencode start with no model reports the chain it will use: {receipt}"
      check (((flat receipt).splitOn "\"requested_model\":null").length >= 2) "no model was requested"
      -- Settled mutating receipts (`start_mission`, `resume_mission`, `cancel_mission`) must carry `status:"completed"` + `result`
      -- (including on idempotent retry and `get_action`) so `verifyMcpActionOutcome` reports `65793` (`action_outcome:"accepted"`,
      -- `receipt_settled:true`, `durable_success:true`, `may_retry_fresh_key:false`) rather than `action_outcome:"rejected"`.
      for (label, raw) in #[("start_mission", receipt), ("start_mission replay", receiptReplay)] do
        let .ok env := OrbBin.Json.parse raw | throw (IO.userError s!"{label} invalid JSON: {raw}")
        let res := env.fieldOrNull "result"
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "status" == some "completed" &&
               res.fieldStr? "state" == some "succeeded" &&
               res.fieldStr? "accepted" == some "yes" &&
               (res.fieldOrNull "result").fieldStr? "effective_model" == some "builtin/smart")
          s!"{label} receipt must normalize to accepted (65793) with durable_success=true: {raw}"
      let startedMid := (((OrbBin.Json.parse receipt).toOption.getD .null).fieldOrNull "result").fieldStr? "mission_id" |>.getD ""
      let startActId := (((OrbBin.Json.parse receipt).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
      let startGetActRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str startActId)]) 4000000000
      let startGetRes := (((OrbBin.Json.parse startGetActRaw).toOption.getD .null).fieldOrNull "result")
      check (verifyReceiptWord startGetRes == 65793 &&
             (startGetRes.fieldOrNull "result").fieldStr? "mission_id" == some startedMid)
        s!"get_action on start_mission must normalize to accepted (65793): {startGetActRaw}"
      let cancelRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "cancel_mission" (.obj #[("mission_id", .str startedMid), ("idempotency_key", .str "cancel-receipt-1")]) 4000000000
      let cancelReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "cancel_mission" (.obj #[("mission_id", .str startedMid), ("idempotency_key", .str "cancel-receipt-1")]) 4000000000
      r24_cancel_without_remote_job_is_success ((OrbBin.Json.parse cancelRaw).toOption.getD .null |>.fieldOrNull "result")
      for (label, raw) in #[("cancel_mission", cancelRaw), ("cancel_mission replay", cancelReplayRaw)] do
        let .ok env := OrbBin.Json.parse raw | throw (IO.userError s!"{label} invalid JSON: {raw}")
        let res := env.fieldOrNull "result"
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "status" == some "completed" &&
               res.fieldStr? "state" == some "succeeded" &&
               (res.fieldOrNull "result").fieldStr? "mission_id" == some startedMid &&
               (res.fieldOrNull "result").fieldStr? "status" == some "cancelled")
          s!"{label} receipt must normalize to accepted (65793) with cancelled result: {raw}"
      let adoptRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "adopt_mission" (.obj #[("mission_id", .str startedMid), ("idempotency_key", .str "adopt-receipt-1")]) 4000000000
      let adoptRes := (((OrbBin.Json.parse adoptRaw).toOption.getD .null).fieldOrNull "result")
      check (verifyReceiptWord adoptRes == 65793 &&
             (adoptRes.fieldOrNull "result").fieldStr? "status" == some "awaiting_user")
        s!"adopt_mission receipt must normalize to accepted (65793): {adoptRaw}"
      -- Unplaced `resume_mission` fails closed with `accepted:"no"` -> `16777474` (`action_outcome:"rejected"`, `durable_success:false`, `may_retry_fresh_key:true`)
      let resumeFailRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "resume_mission" (.obj #[("mission_id", .str startedMid), ("idempotency_key", .str "resume-fail-1")]) 4000000000
      let resumeFailErr := (((OrbBin.Json.parse resumeFailRaw).toOption.getD .null).fieldOrNull "error").setField "accepted" (.str "no")
      check (verifyReceiptWord (.obj #[("error", resumeFailErr)]) == 16777474)
        s!"failed resume_mission must normalize to rejected (16777474): {resumeFailRaw}"
      -- Placed `resume_mission` on a loopback node settles with `65793` (`action_outcome:"accepted"`, `result.status:"active"`) and replays idempotently
      let (nodeListenFd, nodePort) ← match ← LeanSys.Posix.tcpListen "127.0.0.1" 0 8 with
        | .ok p => pure p
        | .error e => throw (IO.userError s!"resume mock node listen failed: {e}")
      let nodeTask ← IO.asTask do
        match ← LeanSys.Posix.tcpAcceptPoll nodeListenFd 5000 with
        | .error _ => pure false
        | .ok cfd =>
          let _ ← LeanSys.Posix.readStreamChunk cfd 8192
          let body := "{\"accepted\":true,\"job_id\":\"j-res-1\"}"
          let resp := s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}"
          let _ ← LeanSys.Posix.writeAll cfd resp.toUTF8
          let _ ← LeanSys.Posix.closeFd cfd
          pure true
      OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES_ENABLED" "true"
      OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES" s!"mockres=http://127.0.0.1:{nodePort}|TURN_OUTCOME_MOCK_TOK"
      OrbBin.PosixExt.setenvVar "TURN_OUTCOME_MOCK_TOK" "secret-mock-tok"
      OrbBin.PosixExt.setenvVar "SANDBOXED_PUBLIC_URL" "http://127.0.0.1:3000"
      discard <| execParamQuery db "UPDATE missions SET tags='[\"remote-node:mockres\"]' WHERE id=?1;" #[startedMid]
      let resumeOkRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "resume_mission" (.obj #[("mission_id", .str startedMid), ("content", .str "Continue."), ("idempotency_key", .str "resume-ok-1")]) 4000000000 (some sup)
      let _ ← IO.ofExcept nodeTask.get
      let _ ← LeanSys.Posix.closeFd nodeListenFd
      OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
      OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
      OrbBin.PosixExt.unsetenvVar "TURN_OUTCOME_MOCK_TOK"
      OrbBin.PosixExt.unsetenvVar "SANDBOXED_PUBLIC_URL"
      let resumeReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "resume_mission" (.obj #[("mission_id", .str startedMid), ("content", .str "Continue."), ("idempotency_key", .str "resume-ok-1")]) 4000000000 (some sup)
      let resumeActId := (((OrbBin.Json.parse resumeOkRaw).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
      let resumeGetActRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str resumeActId)]) 4000000000
      for (label, raw) in #[("resume_mission", resumeOkRaw), ("resume_mission replay", resumeReplayRaw), ("resume_mission get_action", resumeGetActRaw)] do
        let .ok env := OrbBin.Json.parse raw | throw (IO.userError s!"{label} invalid JSON: {raw}")
        let res := env.fieldOrNull "result"
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "status" == some "completed" &&
               res.fieldStr? "state" == some "succeeded" &&
               (res.fieldOrNull "result").fieldStr? "mission_id" == some startedMid &&
               (res.fieldOrNull "result").fieldStr? "status" == some "active")
          s!"{label} receipt must normalize to accepted (65793) with active result: {raw}"
      let cancelActId := (((OrbBin.Json.parse cancelRaw).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
      let cancelGetActRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str cancelActId)]) 4000000000
      let cancelGetRes := (((OrbBin.Json.parse cancelGetActRaw).toOption.getD .null).fieldOrNull "result")
      check (verifyReceiptWord cancelGetRes == 65793 &&
             cancelGetRes.fieldStr? "status" == some "completed" &&
             (cancelGetRes.fieldOrNull "result").fieldStr? "status" == some "cancelled")
        s!"cancel_mission get_action must normalize to accepted (65793) with cancelled result: {cancelGetActRaw}"
      -- `send_message_to_mission` and `schedule_wakeup` also go through `recordSettledMcpAction`:
      -- first answer, retry, and `get_action` must agree (`65793`).
      let sendRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "send_message_to_mission" (.obj #[("mission_id", .str startedMid), ("content", .str "hello"), ("idempotency_key", .str "send-msg-1")]) 4000000000
      let sendReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "send_message_to_mission" (.obj #[("mission_id", .str startedMid), ("content", .str "hello"), ("idempotency_key", .str "send-msg-1")]) 4000000000
      let sendActId := (((OrbBin.Json.parse sendRaw).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
      let sendGetActRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str sendActId)]) 4000000000
      for (label, raw) in #[("send_message_to_mission", sendRaw), ("send_message_to_mission replay", sendReplayRaw), ("send_message_to_mission get_action", sendGetActRaw)] do
        let res := (((OrbBin.Json.parse raw).toOption.getD .null).fieldOrNull "result")
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "status" == some "completed" &&
               (res.fieldOrNull "result").fieldBool? "ok" == some true &&
               (res.fieldOrNull "result").fieldStr? "mission_id" == some startedMid)
          s!"{label} must normalize to accepted (65793): {raw}"
      let wakeRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "schedule_wakeup" (.obj #[("mission_id", .str startedMid), ("delay_seconds", JVal.uint64 60), ("prompt", .str "wake"), ("reason", .str "test"), ("idempotency_key", .str "wake-1")]) 4000000000
      let wakeReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "schedule_wakeup" (.obj #[("mission_id", .str startedMid), ("delay_seconds", JVal.uint64 60), ("prompt", .str "wake"), ("reason", .str "test"), ("idempotency_key", .str "wake-1")]) 4000000000
      let wakeActId := (((OrbBin.Json.parse wakeRaw).toOption.getD .null).fieldOrNull "result").fieldStr? "action_id" |>.getD ""
      let wakeGetActRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str wakeActId)]) 4000000000
      for (label, raw) in #[("schedule_wakeup", wakeRaw), ("schedule_wakeup replay", wakeReplayRaw), ("schedule_wakeup get_action", wakeGetActRaw)] do
        let res := (((OrbBin.Json.parse raw).toOption.getD .null).fieldOrNull "result")
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "status" == some "completed" &&
               (res.fieldOrNull "result").fieldStr? "mission_id" == some startedMid &&
               (res.fieldOrNull "result").fieldStr? "trigger_kind" == some "time")
          s!"{label} must normalize to accepted (65793): {raw}"
      -- Old-shape row recorded before the fix (`result` column holds the partially enriched JSON with mission `status`
      -- and no inner `result` field): both `get_action` and a retry with the same key must still normalize to `65793`
      -- (`action_outcome:"accepted"`, `durable_success:true`, `may_retry_fresh_key:false`) and preserve `result.status`.
      let oldRowJson := s!"\{\"ok\":true,\"mission_id\":\"{startedMid}\",\"status\":\"cancelled\",\"action_id\":\"act-old-cancel\",\"state\":\"succeeded\",\"accepted\":\"yes\"}"
      discard <| execParamQuery store.projectsDb
        ("INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result,created_at,updated_at) " ++
         "VALUES('act-old-cancel',?1,'turn-outcome:m-tools:cancel_mission','old-cancel-key','old-cancel-key','coordinator::m-tools','cancel_mission','{}','succeeded',?2,'t0','t0');")
        #[startedMid, oldRowJson]
      let oldGetRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_action" (.obj #[("action_id", .str "act-old-cancel")]) 4000000000
      let oldReplayRaw ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "cancel_mission" (.obj #[("mission_id", .str startedMid), ("idempotency_key", .str "old-cancel-key")]) 4000000000
      for (label, raw) in #[("old-shape get_action", oldGetRaw), ("old-shape retry", oldReplayRaw)] do
        let res := (((OrbBin.Json.parse raw).toOption.getD .null).fieldOrNull "result")
        check (verifyReceiptWord res == 65793 &&
               res.fieldStr? "action_id" == some "act-old-cancel" &&
               res.fieldStr? "status" == some "completed" &&
               res.fieldStr? "state" == some "succeeded" &&
               (res.fieldOrNull "result").fieldStr? "mission_id" == some startedMid &&
               (res.fieldOrNull "result").fieldStr? "status" == some "cancelled")
          s!"{label} must normalize pre-deploy row to accepted (65793) with result.status=='cancelled': {raw}"
      -- Pending (`state:"accepted"`, `status:"accepted"`) and unknown acceptance (`transportDropped=true` or `accepted:"unknown"`)
      let pendSpawnReceipt := JVal.obj #[("action_id", .str "act-pend-spawn"), ("accepted", .str "yes"), ("state", .str "accepted"), ("status", .str "accepted"), ("tool_name", .str "spawn_managed_machine"), ("result", .obj #[])]
      check (verifyReceiptWord pendSpawnReceipt == 0)
        "pending spawn receipt (state='accepted', status='accepted') must normalize to pending (0, may_retry_fresh_key=false)"
      check (verifyReceiptWord pendSpawnReceipt true == 259)
        "mid-flight transport drop on receipt must normalize to uncertain_reconciliation_required (259, may_retry_fresh_key=false)"
      let .ok _ ← execParamQuery db
          ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cost_cents,mission_id,provider,requested_model) " ++
           "VALUES('t0','glm-5.3',10,5,1,'m-tools','zai','smart');") #[]
        | throw (IO.userError "usage row insert failed")
      let served ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_mission" (.obj #[("mission_id", .str "m-tools")]) 4000000000
      check (((flat served).splitOn "\"served_models\":[{\"requested_model\":\"smart\",\"effective_model\":\"glm-5.3\",\"provider\":\"zai\",\"requests\":1}]").length == 2)
        s!"the mission reports the model that served it: {served}"

      -- `get_mission_events` pages from the newest event unless a cursor says otherwise.
      for i in [0:5] do
        discard <| appendMissionEvent store "m-tools" "assistant_message" s!"\{\"content\":\"reply-{i}\"}" "t2"
      let evPage := fun (extra : Array (String × JVal)) =>
        OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
          "get_mission_events" (.obj (#[("mission_id", .str "m-tools"), ("limit", JVal.uint64 2)] ++ extra)) 4000000000
      let newest := flat (← evPage #[])
      check ((newest.splitOn "reply-4").length == 2 && (newest.splitOn "reply-3").length == 2 &&
             (newest.splitOn "reply-2").length == 1) s!"no cursor returns the newest page: {newest}"
      let maxSeq := ((flat (← evPage #[])).splitOn "\"max_seq\":")[1]? |>.bind (fun s => (s.takeWhile Char.isDigit).toString.toNat?) |>.getD 0
      let back := flat (← evPage #[("before_seq", JVal.uint64 (maxSeq - 1).toUInt64)])
      check ((back.splitOn "reply-2").length == 2 && (back.splitOn "reply-4").length == 1) s!"before_seq pages backwards: {back}"
      let fwd := flat (← evPage #[("since_seq", JVal.uint64 (maxSeq - 1).toUInt64)])
      check ((fwd.splitOn "reply-4").length == 2 && (fwd.splitOn "reply-3").length == 1) s!"since_seq returns newer events: {fwd}"

      -- Library skills reach a node workspace in the directory each harness reads,
      -- including companion `references/**` files (even when `SKILL.md` already exists).
      IO.FS.createDirAll s!"{root}/library/skills/lean-audit/references"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/SKILL.md" "---\nname: lean-audit\n---\nAudit it's \"proofs\".\n"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/references/long-running.md" "# Long-running\nKeep checkpoints.\n"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/references/proof.md" "# Proof\nCheck kernel.\n"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/references/.hidden.md" "hidden"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/references/bad name.md" "unsafe"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/references/id_ed25519" "secret"
      IO.FS.createDirAll s!"{root}/library/skills/Bad Name"
      IO.FS.writeFile s!"{root}/library/skills/Bad Name/SKILL.md" "x"
      let prelude ← OrbCore.Skills.remoteInstallPrelude root none "opencode" "" "" ""
      check ((prelude.splitOn "'.opencode/skills/lean-audit/SKILL.md'").length > 1) s!"opencode skill path: {prelude}"
      check ((prelude.splitOn "'.opencode/skills/lean-audit/references/long-running.md'").length > 1 &&
             (prelude.splitOn "'.opencode/skills/lean-audit/references/proof.md'").length > 1)
        s!"opencode skill companion reference paths: {prelude}"
      check ((prelude.splitOn "Bad Name").length == 1 && (prelude.splitOn "Audit it").length == 1 &&
             (prelude.splitOn ".hidden.md").length == 1 && (prelude.splitOn "bad name.md").length == 1 &&
             (prelude.splitOn "id_ed25519").length == 1)
        "unsafe names, hidden files, and secret filenames are skipped and content is never inlined as shell text"
      let claudePrelude ← OrbCore.Skills.remoteInstallPrelude root none "claude" "" "" ""
      check ((claudePrelude.splitOn "'.claude/skills/lean-audit/SKILL.md'").length > 1 &&
             (claudePrelude.splitOn "'.claude/skills/lean-audit/references/proof.md'").length > 1)
        "claude skill and reference paths"
      -- The script really installs SKILL.md and references/**, and populates missing references even if SKILL.md already exists.
      let ws := s!"{root}/node-workspace"
      IO.FS.createDirAll s!"{ws}/.opencode/skills/lean-audit"
      IO.FS.writeFile s!"{ws}/.opencode/skills/lean-audit/SKILL.md" "---\nname: lean-audit\n---\nAudit it's \"proofs\".\n"
      let sh ← IO.Process.output {
        cmd := "/bin/sh",
        args := #["-c", prelude ++ prelude ++ "cat .opencode/skills/lean-audit/SKILL.md .opencode/skills/lean-audit/references/long-running.md .opencode/skills/lean-audit/references/proof.md"],
        cwd := some ws
      }
      check (sh.exitCode == 0 &&
             sh.stdout == "---\nname: lean-audit\n---\nAudit it's \"proofs\".\n# Long-running\nKeep checkpoints.\n# Proof\nCheck kernel.\n")
        s!"installed skill and references content: {sh.stdout} {sh.stderr}"
      -- A Library whose references exceed the exec argument limit (the 2026-11-15 outage:
      -- every node turn exited 127) ships every SKILL.md and reference via a staged file.
      for i in [0:12] do
        IO.FS.createDirAll s!"{root}/library/skills/big-{i}/references"
        IO.FS.writeFile s!"{root}/library/skills/big-{i}/SKILL.md" s!"---\nname: big-{i}\n---\n{String.ofList (List.replicate 2000 'a')}\n"
        IO.FS.writeFile s!"{root}/library/skills/big-{i}/references/ref.md" (String.ofList (List.replicate 20000 'r'))
      let bigPrelude ← OrbCore.Skills.remoteInstallPrelude root none "opencode" "" "" ""
      check (bigPrelude.utf8ByteSize > 128 * 1024 && bigPrelude.utf8ByteSize ≤ OrbCore.Skills.remoteSkillTotalBytes)
        s!"regression bundle exceeds the exec argument limit: {bigPrelude.utf8ByteSize} bytes"
      check ((List.range 12).all fun i => (bigPrelude.splitOn s!"'.opencode/skills/big-{i}/SKILL.md'").length > 1)
        "every SKILL.md ships before any reference file"
      let (staged, skillEnvs) := OrbCore.RemoteDispatch.stageSkillBundle bigPrelude
      let (promptStage, promptEnvs) := OrbCore.RemoteDispatch.stagePromptOnFd3 "prompt survives skill staging"
      check (staged.utf8ByteSize < 4096 && skillEnvs.all (fun (k, v) => k.utf8ByteSize + 1 + v.utf8ByteSize < 128 * 1024))
        "bundle bytes never enter argv and every environment entry stays below MAX_ARG_STRLEN"
      let bigSh ← IO.Process.output {
        cmd := "/bin/bash", args := #["-lc", staged ++ promptStage ++ "cat <&3; test -z \"${SANDBOXED_SKILL_PART_0+x}\""], cwd := some ws
        env := (skillEnvs ++ promptEnvs).map fun (k, v) => (k, some v)
      }
      check (bigSh.exitCode == 0 && bigSh.stdout == "prompt survives skill staging")
        s!"bash -lc runs the staged bundle and preserves prompt stdin: {bigSh.exitCode} {bigSh.stderr}"
      for i in [0:12] do
        let ref ← IO.FS.readFile s!"{ws}/.opencode/skills/big-{i}/references/ref.md"
        check (ref == String.ofList (List.replicate 20000 'r')) s!"complete reference {i} arrives"
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root

end OrbCore.TurnOutcomeTests
