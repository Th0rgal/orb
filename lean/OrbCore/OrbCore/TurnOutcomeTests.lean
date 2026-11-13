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

private def cellOf (db : SqliteDb) (sql : String) (params : Array String := #[]) : IO String := do
  let .ok rows ← execParamQuery db sql params | throw (IO.userError s!"query failed: {sql}")
  return (rows[1]?.bind (·[0]?)).getD ""

def run : IO Unit := do
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
      let launch : MissionRecord → String → Option String → IO Bool := fun mr _ _ => do
        launches.modify (· + 1)
        discard <| execParamQuery db "UPDATE missions SET status='active' WHERE id=?1;" #[mr.id]
        return true
      let tick := fun (now : UInt64) =>
        discard <| tickContinuationScheduler store none none none sup none root (some launch) (some now)
      tick 4000000000
      check ((← launches.get) == 1 && (← statusOf "m-empty") == "active") "the retry relaunches the turn"
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
      let reply ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "start_mission" (.obj #[("title", .str "ghost"), ("prompt", .str "work that can never start")]) 4000000000
      check ((reply.splitOn "no_execution_placement").length > 1) s!"an undispatchable start is refused: {reply}"
      check ((← cellOf db "SELECT COUNT(*) FROM missions WHERE title='ghost';") == "0") "no ghost mission is left behind"

      -- Receipts name the model asked for and the model the turn is launched with;
      -- afterwards the mission reports which model and provider actually answered.
      let receipt ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "start_mission" (.obj #[("title", .str "receipt"), ("backend", .str "opencode")]) 4000000000
      -- Tool results may carry their JSON as an escaped string: compare without the escapes.
      let flat := fun (raw : String) => raw.replace "\\" ""
      check (((flat receipt).splitOn "\"effective_model\":\"builtin/smart\"").length == 2)
        s!"an opencode start with no model reports the chain it will use: {receipt}"
      check (((flat receipt).splitOn "\"requested_model\":null").length == 2) "no model was requested"
      let .ok _ ← execParamQuery db
          ("INSERT INTO proxy_usage(timestamp,model,input_tokens,output_tokens,cost_cents,mission_id,provider,requested_model) " ++
           "VALUES('t0','glm-5.3',10,5,1,'m-tools','zai','smart');") #[]
        | throw (IO.userError "usage row insert failed")
      let served ← OrbCore.McpGateway.dispatchMcpToolCall store none none none ({} : ManagedFleetState) root claims
        "get_mission" (.obj #[("mission_id", .str "m-tools")]) 4000000000
      check (((flat served).splitOn "\"served_models\":[{\"requested_model\":\"smart\",\"effective_model\":\"glm-5.3\",\"provider\":\"zai\",\"requests\":1}]").length == 2)
        s!"the mission reports the model that served it: {served}"

      -- Library skills reach a node workspace in the directory each harness reads.
      IO.FS.createDirAll s!"{root}/library/skills/lean-audit"
      IO.FS.writeFile s!"{root}/library/skills/lean-audit/SKILL.md" "---\nname: lean-audit\n---\nAudit it's \"proofs\".\n"
      IO.FS.createDirAll s!"{root}/library/skills/Bad Name"
      IO.FS.writeFile s!"{root}/library/skills/Bad Name/SKILL.md" "x"
      let prelude ← OrbCore.Skills.remoteInstallPrelude root none "opencode"
      check ((prelude.splitOn "'.opencode/skills/lean-audit/SKILL.md'").length > 1) s!"opencode skill path: {prelude}"
      check ((prelude.splitOn "Bad Name").length == 1 && (prelude.splitOn "Audit it").length == 1)
        "unsafe names are skipped and content is never inlined as shell text"
      check (((← OrbCore.Skills.remoteInstallPrelude root none "claude").splitOn "'.claude/skills/lean-audit/SKILL.md'").length > 1)
        "claude skill path"
      -- The script really installs the file, and leaves an existing one alone.
      let ws := s!"{root}/node-workspace"
      IO.FS.createDirAll ws
      let sh ← IO.Process.output { cmd := "/bin/sh", args := #["-c", prelude ++ prelude ++ "cat .opencode/skills/lean-audit/SKILL.md"], cwd := some ws }
      check (sh.exitCode == 0 && sh.stdout == "---\nname: lean-audit\n---\nAudit it's \"proofs\".\n") s!"installed skill content: {sh.stdout} {sh.stderr}"
    finally
      closeCoreStore store
  finally
    IO.FS.removeDirAll root

end OrbCore.TurnOutcomeTests
