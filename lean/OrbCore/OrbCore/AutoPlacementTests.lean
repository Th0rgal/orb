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
  finally
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
    closeCoreStore store

def run (root : String) : IO Unit := do
  chooserTests
  gatewayTests root

end OrbCore.AutoPlacementTests
